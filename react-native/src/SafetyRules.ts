import { ModCategory } from './ModerationTypes';
import { CharView, Canonicalizer } from './Canonicalizer';
import { RX } from './TextPrimitives';
import { Lexicons } from './Lexicons';
import { HinglishFold, LeverTaxonomy, LeverClass } from './LanguageFolding';
import { EscalationAnalyser } from './Escalation';

declare const require: (id: string) => any;

export type TargetClass = "person" | "group" | "property" | null;

export interface Finding {
    category: ModCategory;
    confidence: number;
    phrase: string;
    range: [number, number];
    lever?: LeverClass;
    target?: TargetClass;
}

export class SafetyRules {
    private static coercionRX = new RX(
        "coercion",
        "(?:if|unless)\\s+you\\s+(?:don'?t|do\\s+not|refuse|won'?t|dont)[^.!?]{0,60}?(?:i(?:'?ll|\\s+will)?\\s+)?(?:report|review|rate|1\\s*star|one\\s*star|complain|cancel|call\\s+the\\s+police)"
    );

    private static reviewThreatRX = new RX(
        "review-threat",
        "(?:bad|negative|1|one)\\s*(?:star)?\\s*review\\s*(?:unless|if\\s+you|until\\s+you)"
    );

    private static refundExtortRX = new RX(
        "refund-extort",
        "(?:refund|discount|free|money\\s+back|pay\\s+me)[^.!?]{0,40}?or\\s+i(?:'?ll|\\s+will)\\s+(?:report|review|rate|complain|leave|tell|call|post|share|expose|contact|inform|trash|damage|ruin|destroy|wreck|break)"
    );

    private static reviewBargainRX = new RX(
        "review-bargain",
        "(?:(?:refund|waive|comp|discount|fee|paisa|%\\s*(?:back|off)|quietly|penalty).{0,100}(?:\\bor\\b|\\bunless\\b|\\bif\\b|warna|varna|nahi+n?\\s+toh?|nhi+\\s+toh?|still|stays|exchange).{0,80}(?:review|rating|stars?)|(?:review|rating|stars?).{0,100}(?:\\bor\\b|\\bunless\\b|\\bif\\b|warna|varna|nahi+n?\\s+toh?|nhi+\\s+toh?|still|stays|quietly|waive|refund|comp)|(?:don'?t\\s+want|wouldn'?t\\s+want|you(?:'ll|\\s+will)\\s+regret).{0,80}(?:review|rating))"
    );

    static platformBrandTokens: Set<string> = new Set(["wayzyy"]);

    private static urlCandidateRX = new RX(
        "url-candidate",
        "https?://[^\\s<>\"'\\)\\]\\}]+"
    );

    private static maxScannedLinks = 10;

    static platformOwnedRegistrableDomains: Set<string> = new Set(["wayzyy.com"]);

    static get platformOwnedHosts(): Set<string> {
        return this.platformOwnedRegistrableDomains;
    }

    static set platformOwnedHosts(value: Set<string>) {
        this.platformOwnedRegistrableDomains = value;
    }

    static isPlatformOwned(host: string): boolean {
        let h = host.toLowerCase();
        if (h.endsWith(".")) h = h.slice(0, -1);
        if (h.startsWith("www.")) h = h.slice(4);
        
        for (const owned of this.platformOwnedRegistrableDomains) {
            if (h === owned || h.endsWith("." + owned)) return true;
        }
        return false;
    }

    private static carriesBrand(s: string): boolean {
        const lower = s.toLowerCase();
        for (const token of this.platformBrandTokens) {
            if (lower.includes(token)) return true;
        }
        return false;
    }

    private static manualHost(candidate: string): string | null {
        const schemeEnd = candidate.indexOf("://");
        if (schemeEnd === -1) return null;
        const rest = candidate.slice(schemeEnd + 3);
        const match = rest.match(/^([^/?#]+)/);
        if (!match) return null;
        const authority = match[1]!;
        const hostPart = authority.split('@').pop() || authority;
        return hostPart.split(':')[0] || null;
    }

    private static authoritySection(link: string): string {
        const schemeEnd = link.indexOf("://");
        if (schemeEnd === -1) return link;
        const rest = link.slice(schemeEnd + 3);
        const match = rest.match(/^([^/?#]+)/);
        return match ? match[1]! : rest;
    }

    private static brandImpersonation(base: CharView, original: string): Finding | null {
        const text = base.text;
        const originalChars = Array.from(original);

        for (const m of this.urlCandidateRX.matches(text, this.maxScannedLinks)) {
            let candidate = m.text.toLowerCase();
            while (candidate.length > 0 && ".,;:!?".includes(candidate[candidate.length - 1]!)) {
                candidate = candidate.slice(0, -1);
            }

            let host: string | null = null;
            let userinfo: string | null = null;
            try {
                const url = new URL(candidate);
                host = url.hostname;
                userinfo = url.username ? `${url.username}:${url.password}` : null;
            } catch {
                host = this.manualHost(candidate);
            }

            if (!host) continue;

            const finding = (confidence: number, phrase: string): Finding | null => {
                const orig = base.originalRange(m.start, m.end);
                if (!orig) return null;
                return { category: ModCategory.Scam, confidence, phrase, range: orig };
            };

            if (userinfo && this.carriesBrand(userinfo) && !this.isPlatformOwned(host)) {
                const f = finding(0.96, `link displaying the platform name before @ while pointing at ${host}`);
                if (f) return f;
            }

            if (this.isPlatformOwned(host)) {
                const orig = base.originalRange(m.start, m.end);
                if (orig) {
                    const lo = Math.max(0, Math.min(orig[0], originalChars.length));
                    const hi = Math.max(lo, Math.min(orig[1], originalChars.length));
                    const rawLink = originalChars.slice(lo, hi).join('');
                    const authority = this.authoritySection(rawLink);
                    if (/[^\x00-\x7F]/.test(authority)) {
                        const f = finding(0.96, "link using look-alike characters to imitate the platform domain");
                        if (f) return f;
                    }
                }
                continue;
            }

            if (this.carriesBrand(host)) {
                const f = finding(0.96, `link impersonating the platform: ${host}`);
                if (f) return f;
            }

            if (host.includes("xn--")) {
                const f = finding(0.82, `link using an encoded international domain: ${host}`);
                if (f) return f;
            }
        }
        return null;
    }

    private static profanity(alpha: CharView, alphaCompact: CharView): Finding | null {
        const { SlurLexicon } = require('./SlurLexicon');
        const tokens = Canonicalizer.tokenize(alpha).filter(t => t.isWord);
        if (tokens.length === 0) return null;
        const words = tokens.map(t => t.text);

        const rangeFor = (index: number): [number, number] | null =>
            alpha.originalRange(tokens[index]!.start, tokens[index]!.end);

        const joined = words.join(" ");
        for (const phrase of Lexicons.slurTerms) {
            if (phrase.includes(" ") && joined.includes(phrase)) {
                const upper = Math.max(1, (alpha.offsets[alpha.offsets.length - 1] ?? 0) + 1);
                return { category: ModCategory.Harassment, confidence: 0.97, phrase: "slur", range: [0, upper], target: "group" };
            }
        }

        const skeletonWords = new Set(words.map(w => HinglishFold.skeleton(w)));
        if (SlurLexicon.matchesSkeleton(skeletonWords)) {
            const upper = Math.max(1, (alpha.offsets[alpha.offsets.length - 1] ?? 0) + 1);
            return { category: ModCategory.Harassment, confidence: 0.97, phrase: "slur (skeleton match)", range: [0, upper], target: "group" };
        }

        for (let i = 0; i < words.length; i++) {
            if (!Lexicons.slurTerms.has(words[i]!)) continue;
            const r = rangeFor(i);
            if (!r) continue;
            return { category: ModCategory.Harassment, confidence: 0.97, phrase: "slur", range: r };
        }

        const window = 4;
        for (let i = 0; i < words.length; i++) {
            const w = words[i]!;
            const indic = Lexicons.profanityIndic.has(w);
            const strong = Lexicons.profanityStrong.has(w);
            const mild = Lexicons.profanityMild.has(w);
            if (!(indic || strong || mild)) continue;

            const lo = Math.max(0, i - window), hi = Math.min(words.length - 1, i + window);
            let person = false, property = false;
            for (let j = lo; j <= hi; j++) {
                if (j === i) continue;
                if (Lexicons.personTargets.has(words[j]!)) person = true;
                if (Lexicons.propertyTargets.has(words[j]!)) property = true;
            }

            if (property && !person) continue;
            if (!person) continue;

            const r = rangeFor(i);
            if (!r) continue;
            const confidence = indic ? 0.94 : (strong ? 0.90 : 0.74);
            return {
                category: ModCategory.Harassment,
                confidence,
                phrase: "profanity directed at a person",
                range: r
            };
        }

        const filler = new Set(["*", "#", "-", "_", ".", "+", "~", "^"]);
        const destarred = Array.from(alpha.text).filter(c => !filler.has(c)).join("");
        if (destarred !== alpha.text) {
            for (const w of destarred.split(/[^a-zA-Z0-9]+/)) {
                const word = w.toLowerCase();
                const indic = Lexicons.profanityIndic.has(word);
                const strong = Lexicons.profanityStrong.has(word);
                if (!(indic || strong || Lexicons.slurTerms.has(word))) continue;
                if (!words.some(x => Lexicons.personTargets.has(x))) continue;
                const upper = Math.max(1, (alpha.offsets[alpha.offsets.length - 1] ?? 0) + 1);
                return {
                    category: ModCategory.Harassment,
                    confidence: indic ? 0.94 : 0.90,
                    phrase: "profanity directed at a person",
                    range: [0, upper]
                };
            }
        }
        return null;
    }

    private static readonly agentRequiredThreats = new Set([
        "kill you", "hurt you", "beat you up", "break your legs", "smash your face",
        "burn your house", "you will regret"
    ]);

    private static readonly visitThreats = new Set([
        "come to your house"
    ]);

    private static readonly firstPersonAgents = new Set([
        "i", "im", "ive", "ill", "id", "we", "well", "weve", "were", "us", "me", "my",
        "main", "mai", "mein", "hum", "humne", "maine"
    ]);

    private static readonly offerModals = new Set([
        "can", "could", "may", "shall", "should", "might", "would"
    ]);

    private static readonly serviceVerbs = new Set([
        "inspect", "repair", "fix", "check", "clean", "service", "servicing", "maintenance",
        "deliver", "collect", "drop", "install", "replace", "sort", "arrange", "help",
        "bring", "pick", "show", "handover", "hand", "meet", "assist"
    ]);

    private static targetRequiredHarassment: Set<string> = new Set([
        "worthless", "moron", "imbecile", "pathetic loser", "disgusting person"
    ]);

    private static wordsBefore(text: string, index: number, limit: number): string[] {
        const prefix = text.slice(0, index);
        return prefix
            .split(/[^a-zA-Z0-9]+/)
            .filter(w => w.length > 0)
            .slice(-limit);
    }

    static threatContextHolds(phrase: string, start: number, text: string): boolean {
        const needsAgent = this.agentRequiredThreats.has(phrase);
        const isVisit = this.visitThreats.has(phrase);
        if (!(needsAgent || isVisit)) return true;

        const preceding = this.wordsBefore(text, start, 8);
        if (!preceding.some(w => this.firstPersonAgents.has(w))) return false;
        if (!isVisit) return true;

        const offered = preceding.some(w => this.offerModals.has(w));
        const servicing = text
            .split(/[^a-zA-Z0-9]+/)
            .some(w => this.serviceVerbs.has(w));
        return !(offered || servicing);
    }

    static harassmentTargetHolds(phrase: string, words: string[]): boolean {
        if (!this.targetRequiredHarassment.has(phrase)) return true;
        return words.some(w => Lexicons.personTargets.has(w));
    }

    private static readonly phishingMechanismTerms = new Set([
        "link", "links", "click", "clicking", "url", "website", "portal",
        "otp", "password", "passcode", "pin", "cvv", "cvc", "code",
        "card", "debit", "credit", "netbanking", "login", "signin",
        "upi", "wallet", "paytm", "gpay", "phonepe", "transfer", "gift"
    ]);

    private static hasPhishingMechanism(text: string): boolean {
        const lower = text.toLowerCase();
        if (lower.includes("http") || lower.includes("www.")) return true;
        const words = lower.split(/[^a-zA-Z0-9]+/).filter(w => w.length > 0);
        return words.some(w => this.phishingMechanismTerms.has(w));
    }

    static semanticFindingHolds(finding: Finding, text: string): boolean {
        switch (finding.category) {
            case ModCategory.Harassment: {
                const words = text.split(/[^a-zA-Z0-9]+/).filter(w => w.length > 0);
                if (words.some(w => Lexicons.personTargets.has(w))) return true;
                return EscalationAnalyser.addressesPersonNativeScript(text);
            }
            case ModCategory.Scam:
                return this.hasPhishingMechanism(text);
            default:
                return true;
        }
    }

    private static indicProfanitySkeletons = HinglishFold.skeletonSet(Lexicons.profanityIndic);

    private static skeletonProfanity(skeleton: CharView, surface: string): Finding | null {
        if (skeleton.isEmpty) return null;
        const skeletonWords = new Set(skeleton.text.split(" ").filter(w => w.length > 0));
        if (skeletonWords.size === 0) return null;

        let intersects = false;
        for (const w of skeletonWords) {
            if (this.indicProfanitySkeletons.has(w)) { intersects = true; break; }
        }
        if (!intersects) return null;

        const surfaceWords = surface.split(/[^a-zA-Z0-9]+/).filter(w => w.length > 0);
        const person = surfaceWords.some(w => Lexicons.personTargets.has(w))
            || EscalationAnalyser.addressesPersonNativeScript(surface);
        const property = surfaceWords.some(w => Lexicons.propertyTargets.has(w));

        if (!person) return null;
        if (property && !person) return null;

        const upper = Math.max(1, (skeleton.offsets[skeleton.offsets.length - 1] ?? 0) + 1);
        return {
            category: ModCategory.Harassment,
            confidence: 0.94,
            phrase: "profanity directed at a person (skeleton match)",
            range: [0, upper],
            target: "person"
        };
    }

    // Evaluates safety rules based on lexical matching, regex, and exact character maps.
    static evaluate(
        base: CharView,
        alpha: CharView,
        alphaCompact: CharView,
        skeleton?: CharView | null,
        original: string = ""
    ): Finding[] {
        const text = HinglishFold.foldOtherwise(base.text);
        if (!text) return [];

        let findings: Finding[] = [];

        const phish = this.brandImpersonation(base, original || text);
        if (phish) findings.push(phish);

        const { Discrimination } = require('./Discrimination');
        const bias = Discrimination.discrimination(base, original);
        if (bias) findings.push(bias);

        const abuse = this.profanity(alpha, alphaCompact);
        if (abuse) findings.push(abuse);
        else if (skeleton) {
            const skelAbuse = this.skeletonProfanity(skeleton, text);
            if (skelAbuse) findings.push(skelAbuse);
        }

        const scan = (phrases: string[], category: ModCategory, confidence: number, gate?: (p: string, i: number) => boolean) => {
            if (!phrases) return;
            for (const phrase of phrases) {
                const start = text.indexOf(phrase);
                if (start === -1) continue;
                if (gate && !gate(phrase, start)) continue;

                const end = start + phrase.length;
                const orig = base.originalRange(start, end);
                if (!orig) continue;

                findings.push({ category, confidence, phrase, range: orig });
                return;
            }
        };

        const messageWords = text.split(/[^a-zA-Z0-9]+/).filter(w => w.length > 0);

        scan(Lexicons.selfHarmPhrases || [], ModCategory.SelfHarm, 0.90);
        scan(Lexicons.threatPhrases || [], ModCategory.Threat, 0.93, (phrase, start) =>
            this.threatContextHolds(phrase, start, text)
        );
        scan(Lexicons.sexualPhrases || [], ModCategory.Sexual, 0.88);
        scan(Lexicons.harassmentPhrases || [], ModCategory.Harassment, 0.74, (phrase, _) => {
            return this.harassmentTargetHolds(phrase, messageWords);
        });
        scan(Lexicons.scamPhrases || [], ModCategory.Scam, 0.82);

        // Coercion
        const leverClass = LeverTaxonomy.classify(text);
        if (leverClass === LeverClass.illegitimate) {
            scan(Lexicons.coercionPhrases || [], ModCategory.Coercion, 0.78);

            const rxList = [this.coercionRX, this.reviewThreatRX, this.refundExtortRX, this.reviewBargainRX];
            for (const rx of rxList) {
                if (findings.some(f => f.category === ModCategory.Coercion)) break;

                for (const m of rx.matches(text, 1)) {
                    const orig = base.originalRange(m.start, m.end);
                    if (!orig) continue;
                    findings.push({
                        category: ModCategory.Coercion,
                        confidence: 0.88,
                        phrase: m.text,
                        range: orig,
                        lever: LeverClass.illegitimate
                    });
                }
            }

            if (!findings.some(f => f.category === ModCategory.Coercion)) {
                const span: [number, number] = [0, Math.max(1, Math.min(text.length, 120))];
                const orig = base.originalRange(span[0], span[1]) ?? span;
                findings.push({
                    category: ModCategory.Coercion,
                    confidence: 0.86,
                    phrase: text.slice(0, 80),
                    range: orig,
                    lever: LeverClass.illegitimate
                });
            }
        }

        findings = findings.map(f => {
            if (f.category === ModCategory.Coercion && !f.lever) {
                return { ...f, lever: leverClass };
            }
            return f;
        });

        return findings;
    }
}
