import { ModCategory, ModAction, Detection, ActorContext, getTrustTierThresholdOffset, getBookingStageThresholdOffset } from './ModerationTypes';
import { SafetyRules, Finding } from './SafetyRules';

export interface Thresholds {
    hint: number;
    mask: number;
    withhold: number;
}

export const baseThresholds: Thresholds = {
    hint: 0.22,
    mask: 0.38,
    withhold: 0.60
};

export interface Configuration {
    version: string;
    baseThresholds: Thresholds;
    trustOffsets: Record<string, number>;
    stageOffsets: Record<string, number>;
    violationPenalty: number;
    maxPriorsCounted: number;
    repeatOffenderBlockAt: number;
    repeatOffenderWarnAt: number;
    explicitIdentifierFloor: number;
    safetyActions: Record<string, string>;
    scamBlockConfidence: number;
    provisionalHoldEnabled: boolean;
    criticalSeverity: string[];
}

export const v1Configuration: Configuration = {
    version: "2026-08-18.v2",
    baseThresholds: baseThresholds,
    trustOffsets: {},
    stageOffsets: {},
    violationPenalty: 0.05,
    maxPriorsCounted: 3.0,
    repeatOffenderBlockAt: 3,
    repeatOffenderWarnAt: 2,
    explicitIdentifierFloor: 0.65,
    safetyActions: {
        [ModCategory.Threat]: ModAction.Block,
        [ModCategory.Sexual]: ModAction.Block,
        [ModCategory.Coercion]: ModAction.Block,
        [ModCategory.Harassment]: ModAction.Warn,
        [ModCategory.Discrimination]: ModAction.Block,
    },
    scamBlockConfidence: 0.95,
    provisionalHoldEnabled: true,
    criticalSeverity: [ModCategory.Threat, ModCategory.Sexual]
};

export interface Decision {
    action: ModAction;
    threshold: number;
    reasonCodes: string[];
}

export class Policy {
    static thresholds(actor: ActorContext, config: Configuration = v1Configuration): Thresholds {
        const t = { ...config.baseThresholds };
        // Assuming ActorContext trust/stage offset mapping. For JS, if not mapped directly, default to 0.
        // We'll map them strictly if provided, otherwise 0
        const trustOffset = config.trustOffsets[actor.trust] ?? getTrustTierThresholdOffset(actor.trust);
        const stageOffset = config.stageOffsets[actor.stage] ?? getBookingStageThresholdOffset(actor.stage);
        const offset = trustOffset + stageOffset;
        
        const violationPenalty = Math.min(actor.priorViolations, config.maxPriorsCounted) * config.violationPenalty;

        t.hint = this.clamp(t.hint + offset - violationPenalty);
        t.mask = this.clamp(t.mask + offset - violationPenalty);
        t.withhold = this.clamp(t.withhold + offset - violationPenalty);
        return t;
    }

    static decide(
        score: number,
        contactDetections: Detection[],
        safetyFindings: Finding[],
        actor: ActorContext,
        advisoryOnly: boolean,
        config: Configuration = v1Configuration
    ): Decision {
        const t = this.thresholds(actor, config);
        const reasons: string[] = [];
        let action: ModAction = ModAction.Allow;

        if (contactDetections.length > 0) {
            if (score >= t.withhold) {
                if (actor.priorViolations >= config.repeatOffenderBlockAt) {
                    action = ModAction.Block;
                    reasons.push("CONTACT_EXFIL_REPEAT_OFFENDER");
                } else if (actor.priorViolations >= config.repeatOffenderWarnAt) {
                    action = ModAction.Warn;
                    reasons.push("CONTACT_EXFIL_REPEATED");
                } else {
                    action = ModAction.Mask;
                    reasons.push("CONTACT_EXFIL_HIGH");
                }
            } else if (score >= t.mask) {
                action = ModAction.Mask;
                reasons.push("CONTACT_EXFIL_MASK");
            } else if (score >= t.hint) {
                action = ModAction.Hint;
                reasons.push("CONTACT_EXFIL_LOW");
            } else {
                reasons.push("CONTACT_EXFIL_BELOW_THRESHOLD");
            }

            const literalIdentifier = new Set([
                ModCategory.Phone, ModCategory.Email, ModCategory.SocialHandle, 
                ModCategory.PaymentHandle, ModCategory.CryptoAddress, ModCategory.BankDetails
            ]);
            
            const hasExplicitIdentifier = contactDetections.some(d => 
                literalIdentifier.has(d.category as ModCategory) &&
                d.confidence >= config.explicitIdentifierFloor &&
                !d.transforms.includes("semantic-retrieval") &&
                !d.transforms.includes("semantic-judge")
            );

            if (hasExplicitIdentifier && this.actionRank(action) < this.actionRank(ModAction.Mask)) {
                action = ModAction.Mask;
                reasons.push("CONTACT_EXPLICIT_IDENTIFIER_FLOOR");
            }

            const cats = Array.from(new Set(contactDetections.map(d => d.category))).sort();
            for (const c of cats) {
                reasons.push(`CAT_${c.toUpperCase()}`);
            }
            if (contactDetections.some(d => d.effort >= 5)) {
                reasons.push("HIGH_OBFUSCATION_EFFORT");
            }
        }

        for (const finding of safetyFindings) {
            switch (finding.category) {
                case ModCategory.SelfHarm:
                    reasons.push("SAFETY_SELF_HARM_SUPPORT");
                    break;
                case ModCategory.Scam:
                    if (finding.confidence >= config.scamBlockConfidence) {
                        action = this.maxAction(action, ModAction.Block);
                        reasons.push("SAFETY_PHISHING");
                    } else {
                        action = this.maxAction(action, ModAction.Block);
                        reasons.push("SAFETY_SCAM");
                    }
                    break;
                default:
                    const mappedStr = config.safetyActions[finding.category];
                    if (mappedStr) {
                        action = this.maxAction(action, mappedStr as ModAction);
                        reasons.push(`SAFETY_${finding.category.toUpperCase()}`);
                    }
                    break;
            }
        }

        if (advisoryOnly && this.actionRank(action) > this.actionRank(ModAction.Hint)) {
            action = ModAction.Hint;
        }

        if (action === ModAction.Allow && reasons.length === 0) {
            reasons.push("CLEAN");
        }

        return { action, threshold: t.mask, reasonCodes: reasons };
    }

    private static actionRank(a: ModAction): number {
        const ranks: Record<string, number> = {
            [ModAction.Allow]: 0,
            [ModAction.Hint]: 1,
            [ModAction.Mask]: 2,
            [ModAction.Review]: 3,
            [ModAction.Warn]: 4,
            [ModAction.Block]: 5
        };
        return ranks[a] ?? 0;
    }

    static rank(a: ModAction): number {
        return this.actionRank(a);
    }

    private static maxAction(a: ModAction, b: ModAction): ModAction {
        return this.actionRank(a) >= this.actionRank(b) ? a : b;
    }

    private static clamp(v: number): number {
        return Math.min(Math.max(v, 0.05), 0.97);
    }

    static redact(original: string, detections: Detection[]): string {
        if (detections.length === 0) return original;
        const chars = Array.from(original);

        const ranges = detections.map(d => d.range).sort((a, b) => a[0] - b[0]);
        const merged: [number, number][] = [];
        for (const r of ranges) {
            const lower = Math.max(0, r[0]);
            const upper = Math.min(chars.length, r[1]);
            if (lower >= upper) continue;
            
            const last = merged[merged.length - 1];
            if (last && lower <= last[1]) {
                merged[merged.length - 1] = [last[0], Math.max(last[1], upper)];
            } else {
                merged.push([lower, upper]);
            }
        }

        let out = "";
        let cursor = 0;
        for (const r of merged) {
            if (cursor < r[0]) {
                out += chars.slice(cursor, r[0]).join('');
            }
            const count = Math.min(Math.max(r[1] - r[0], 3), 10);
            out += "●".repeat(count);
            cursor = r[1];
        }
        if (cursor < chars.length) {
            out += chars.slice(cursor).join('');
        }
        return out;
    }
}
