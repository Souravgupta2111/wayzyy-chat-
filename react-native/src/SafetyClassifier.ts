import { ModCategory } from './ModerationTypes';
import { SafetyRules, Finding } from './SafetyRules';

export enum SafetyHead {
    threat = "threat",
    harassment = "harassment",
    sexual = "sexual",
    selfHarm = "selfHarm",
    coercion = "coercion",
    scam = "scam",
    legitimateComplaint = "legitimateComplaint"
}

export function getSafetyHeadCategory(head: SafetyHead): ModCategory | null {
    switch (head) {
        case SafetyHead.threat: return ModCategory.Threat;
        case SafetyHead.harassment: return ModCategory.Harassment;
        case SafetyHead.sexual: return ModCategory.Sexual;
        case SafetyHead.selfHarm: return ModCategory.SelfHarm;
        case SafetyHead.coercion: return ModCategory.Coercion;
        case SafetyHead.scam: return ModCategory.Scam;
        case SafetyHead.legitimateComplaint: return null;
    }
}

export function getSafetyHeadDisplay(head: SafetyHead): string {
    switch (head) {
        case SafetyHead.threat: return "Threat";
        case SafetyHead.harassment: return "Harassment";
        case SafetyHead.sexual: return "Sexual";
        case SafetyHead.selfHarm: return "Self-harm";
        case SafetyHead.coercion: return "Coercion";
        case SafetyHead.scam: return "Scam / phishing";
        case SafetyHead.legitimateComplaint: return "Legitimate complaint";
    }
}

export class SafetyScores {
    scores: Partial<Record<SafetyHead, number>> = {};
    source: string;
    latencyMs: number;

    constructor(source: string, latencyMs: number, scores: Partial<Record<SafetyHead, number>> = {}) {
        this.source = source;
        this.latencyMs = latencyMs;
        this.scores = scores;
    }

    get(head: SafetyHead): number {
        return this.scores[head] ?? 0;
    }

    set(head: SafetyHead, value: number) {
        this.scores[head] = Math.min(Math.max(value, 0), 1);
    }

    raise(head: SafetyHead, value: number) {
        this.set(head, Math.max(this.get(head), value));
    }

    get strongestViolation(): { head: SafetyHead, score: number } | null {
        let bestHead: SafetyHead | null = null;
        let bestScore = 0;
        
        for (const [key, val] of Object.entries(this.scores)) {
            const head = key as SafetyHead;
            if (head === SafetyHead.legitimateComplaint) continue;
            if (val !== undefined && val > bestScore) {
                bestScore = val;
                bestHead = head;
            }
        }
        
        if (bestHead && bestScore > 0) {
            return { head: bestHead, score: bestScore };
        }
        return null;
    }

    get legitimateComplaint(): number {
        return this.get(SafetyHead.legitimateComplaint);
    }

    get isEmpty(): boolean {
        return Object.values(this.scores).every(v => (v || 0) <= 0);
    }
}

export enum SafetyBand {
    allow = "allow",
    route = "route",
    enforce = "enforce"
}

export class SafetyCalibration {
    enforce: Partial<Record<SafetyHead, number>>;
    route: Partial<Record<SafetyHead, number>>;
    enforcementEnabled: boolean;
    complaintVeto: number = 0.55;

    constructor(enforce: Partial<Record<SafetyHead, number>>, route: Partial<Record<SafetyHead, number>>, enforcementEnabled: boolean) {
        this.enforce = enforce;
        this.route = route;
        this.enforcementEnabled = enforcementEnabled;
    }

    static get default(): SafetyCalibration {
        return new SafetyCalibration(
            {
                [SafetyHead.threat]: 0.90, [SafetyHead.harassment]: 0.90, [SafetyHead.sexual]: 0.90,
                [SafetyHead.selfHarm]: 0.80, [SafetyHead.coercion]: 0.92, [SafetyHead.scam]: 0.92,
            },
            {
                [SafetyHead.threat]: 0.35, [SafetyHead.harassment]: 0.40, [SafetyHead.sexual]: 0.35,
                [SafetyHead.selfHarm]: 0.30, [SafetyHead.coercion]: 0.32, [SafetyHead.scam]: 0.45,
            },
            false
        );
    }

    band(head: SafetyHead, score: number): SafetyBand {
        if (head === SafetyHead.legitimateComplaint) return SafetyBand.allow;
        
        const enforceBar = this.enforce[head];
        if (this.enforcementEnabled && enforceBar !== undefined && score >= enforceBar) {
            return SafetyBand.enforce;
        }
        
        const routeBar = this.route[head];
        if (routeBar !== undefined && score >= routeBar) {
            return SafetyBand.route;
        }
        
        return SafetyBand.allow;
    }
}

export interface SafetyClassifierInput {
    text: string;
    deterministicFindings: Finding[];
    safetySimilarity: number;
    innocentSimilarity: number;
    addressesPerson: boolean;
    conditionalDemand: boolean;
    propertyDirected: boolean;
    reviewBargainScore: number;
}

export interface SafetyClassifier {
    identifier: string;
    calibration: SafetyCalibration;
    classify(input: SafetyClassifierInput): SafetyScores;
}

export class SignalDerivedSafetyClassifier implements SafetyClassifier {
    identifier = "signal-derived-v1";
    calibration: SafetyCalibration;

    static marginDeadZone = 0.05;

    constructor(calibration: SafetyCalibration = SafetyCalibration.default) {
        this.calibration = calibration;
    }

    classify(input: SafetyClassifierInput): SafetyScores {
        const startTime = Date.now();
        const out = new SafetyScores(this.identifier, 0);

        for (const finding of input.deterministicFindings) {
            const head = Object.values(SafetyHead).find(h => getSafetyHeadCategory(h) === finding.category);
            if (head) {
                out.raise(head, finding.confidence);
            }
        }

        if (input.safetySimilarity >= 0 && input.innocentSimilarity >= 0) {
            const margin = input.safetySimilarity - input.innocentSimilarity;
            if (margin > SignalDerivedSafetyClassifier.marginDeadZone) {
                const weak = Math.min(margin * 3.0, 0.72);
                out.raise(SafetyHead.harassment, weak);
                if (input.addressesPerson) out.raise(SafetyHead.threat, weak * 0.85);
            }
        }

        if (input.conditionalDemand) {
            out.raise(SafetyHead.coercion, input.addressesPerson ? 0.52 : 0.44);
        }
        if (input.reviewBargainScore > 0) {
            out.raise(SafetyHead.coercion, input.reviewBargainScore);
        }

        let complaint = 0.0;
        if (input.propertyDirected) {
            complaint = input.addressesPerson ? 0.58 : 0.72;
        }
        if (input.innocentSimilarity >= 0.30) {
            complaint = Math.max(complaint, input.innocentSimilarity);
        }
        if (input.deterministicFindings.some(f => f.confidence >= 0.90)) {
            complaint = 0;
        }
        if (input.reviewBargainScore >= 0.55) {
            complaint = 0;
        }
        out.set(SafetyHead.legitimateComplaint, complaint);

        out.latencyMs = Date.now() - startTime;
        return out;
    }
}

// NOTE: RemoteSafetyClassifier uses URLSession and backend calls, which violates 
// the client-side environment requirements. We omit it here. If required, 
// a fetch-based stub can be provided for remote calls.

export interface SafetyCalibrationOutcome {
    finding?: Finding;
    shouldRoute: boolean;
    reasonCodes: string[];
    drivingHead?: SafetyHead;
    drivingScore: number;
    complaintVetoed: boolean;
}

export function applySafetyCalibration(calibration: SafetyCalibration, scores: SafetyScores, textLength: number): SafetyCalibrationOutcome {
    const out: SafetyCalibrationOutcome = {
        shouldRoute: false,
        reasonCodes: [],
        drivingScore: 0,
        complaintVetoed: false
    };

    const strongest = scores.strongestViolation;
    if (!strongest) return out;

    const { head, score } = strongest;
    out.drivingHead = head;
    out.drivingScore = score;

    const band = calibration.band(head, score);
    if (band === SafetyBand.allow) return out;

    const vetoed = scores.legitimateComplaint >= calibration.complaintVeto && head !== SafetyHead.coercion;
    if (vetoed) out.complaintVetoed = true;

    switch (band) {

        case SafetyBand.route:
            out.shouldRoute = true;
            out.reasonCodes.push(`LAYER3_ROUTE(${head} ${score.toFixed(2)})`);
            break;
        case SafetyBand.enforce:
            if (vetoed) {
                out.shouldRoute = true;
                out.reasonCodes.push(`LAYER3_COMPLAINT_VETO(${scores.legitimateComplaint.toFixed(2)})`);
            } else {
                const category = getSafetyHeadCategory(head);
                if (category) {
                    out.finding = {
                        category,
                        confidence: score,
                        phrase: `${getSafetyHeadDisplay(head)} — classifier ${score.toFixed(2)} (${scores.source})`,
                        range: [0, Math.max(1, textLength)]
                    };
                    out.reasonCodes.push(`LAYER3_ENFORCED(${head} ${score.toFixed(2)})`);
                }
            }
            break;
    }

    return out;
}
