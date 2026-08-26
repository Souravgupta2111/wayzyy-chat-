import { CharView, Canonicalizer, CanonicalizerViews } from './Canonicalizer';
import { Detection, isContactExfiltration } from './ModerationTypes';
import { Extractors } from './Extractors';
import { RX } from './TextPrimitives';
import { Lexicons } from './Lexicons';
import { PositionalChannels } from './PositionalChannels';
import { LeverTaxonomy } from './LanguageFolding';
import { Signals } from './Scorer';

export { Suspicion } from './ModerationTypes';
export type { CarrierCandidate } from './ModerationTypes';
import { Suspicion, CarrierCandidate } from './ModerationTypes';

/** Shared similarity/margin bar shape used by retrieval thresholds. */
export interface RetrievalThresholds {
    similarity: number;
    margin: number;
}

export class EscalationResult {
    suspicions: Suspicion[] = [];
    carriers: CarrierCandidate[] = [];

    get isEmpty(): boolean {
        return this.suspicions.length === 0;
    }

    get reasonCode(): string | null {
        if (this.suspicions.length === 0) return null;
        return `SUSPICION(${this.suspicions.join(",")})`;
    }
}

export class EscalationAnalyser {
    static escalationMargin = 0.05;
    static escalationSimilarity = 0.24;
    static innocentFamiliarityFloor = 0.20;
    static personDirectedLead = 0.02;

    static readonly assemblyCues = [
        "those two together", "two together", "both together", "them together",
        "put them together", "put those together", "put both", "combine them",
        "combine both", "combine those", "stick them", "stick it after",
        "one after the other", "add them after", "join those", "join both",
        "note it down", "note this down", "note that down", "write it down",
        "write this down", "write down carefully", "write them down",
        "save this somewhere", "save those", "remember both", "remember those",
        "you will work out the rest", "work out the rest", "figure out the rest",
        "read the numbers only", "numbers only", "only the digits"
    ];

    analyse(
        original: string,
        views: CanonicalizerViews,
        detections: Detection[],
        suppressedOnly: boolean,
        signals: Signals,
        allowExpensiveTiers: boolean,
        retrievalMargin: number = 0,
        retrievalSimilarity: number = 0,
        escalationThresholds: RetrievalThresholds | null = null,
        safetyInnocentSimilarity: number = -1,
        safetySimilarity: number = -1,
        classifierRouted: boolean = false
    ): EscalationResult {
        const result = new EscalationResult();

        const addressesPerson = EscalationAnalyser.addressesPerson(views.alpha) || EscalationAnalyser.addressesPersonNativeScript(original);
        if (addressesPerson && safetyInnocentSimilarity >= 0) {
            const novel = safetyInnocentSimilarity < EscalationAnalyser.innocentFamiliarityFloor;
            const closerToAbuse = safetySimilarity >= 0 && safetySimilarity > safetyInnocentSimilarity + EscalationAnalyser.personDirectedLead;
            if (novel || closerToAbuse) {
                result.suspicions.push(Suspicion.personDirectedAnomaly);
            }
        }

        if (EscalationAnalyser.conditionalDemand(views.base.text) || 
            EscalationAnalyser.nativeConditionalDemand(original) || 
            LeverTaxonomy.isReviewBargain(original) || 
            LeverTaxonomy.isReviewBargain(views.base.text)) {
            result.suspicions.push(Suspicion.conditionalDemand);
        }

        if (classifierRouted) {
            result.suspicions.push(Suspicion.classifierUncertain);
        }

        if (EscalationAnalyser.promptManipulation(views.base.text)) {
            result.suspicions.push(Suspicion.promptManipulation);
        }

        const hasContactDetection = detections.some(d => isContactExfiltration(d.category));
        if (hasContactDetection && !suppressedOnly) return result;

        const fragment = EscalationAnalyser.dictatedFragment(original, views.digits.text);
        if (fragment) {
            result.suspicions.push(Suspicion.dictatedFragment);
            result.carriers.push(fragment);
        }

        if (suppressedOnly) {
            const run = EscalationAnalyser.contiguousMobile(views.base.text);
            if (run) {
                result.suspicions.push(Suspicion.suppressedPhoneShape);
                result.carriers.push({
                    channel: "contiguous digit run",
                    payload: run,
                    validates: true,
                    shape: "phone number"
                });
            }
        }

        if (allowExpensiveTiers) {
            const carriers = EscalationAnalyser.positionalCarriers(original);
            if (carriers.length > 0) {
                result.suspicions.push(Suspicion.positionalCarrier);
                result.carriers.push(...carriers);
            }
        }

        const domain = EscalationAnalyser.obfuscatedDomain(views.base.text);
        if (domain) {
            result.suspicions.push(Suspicion.spacedDomain);
            result.carriers.push(domain);
        }

        if (EscalationAnalyser.wordlessProtocolCue(original, signals)) {
            result.suspicions.push(Suspicion.wordlessProtocolCue);
        }

        if (allowExpensiveTiers && EscalationAnalyser.anomalousRegularity(original)) {
            result.suspicions.push(Suspicion.anomalousRegularity);
        }

        if (EscalationAnalyser.intentWithoutPayload(views.base.text, retrievalMargin, retrievalSimilarity, escalationThresholds)) {
            result.suspicions.push(Suspicion.intentWithoutPayload);
        }

        return result;
    }

    static intentWithoutPayload(text: string, retrievalMargin: number, retrievalSimilarity: number = 0, thresholds?: RetrievalThresholds | null): boolean {
        const simBar = thresholds?.similarity ?? this.escalationSimilarity;
        const marginBar = thresholds?.margin ?? this.escalationMargin;
        if (retrievalSimilarity >= simBar && retrievalMargin >= marginBar) {
            return true;
        }
        const lists = [Lexicons.solicitationCues, Lexicons.steeringCues, Lexicons.pretextCues, EscalationAnalyser.assemblyCues];
        for (const list of lists) {
            if (!list) continue;
            for (const phrase of list) {
                if (text.includes(phrase)) return true;
            }
        }
        return false;
    }

    static promptManipulation(text: string): boolean {
        const unambiguous = [
            "ignore previous instruction", "ignore all previous",
            "ignore your instruction", "disregard previous",
            "disregard your instruction", "forget your instruction",
            "system prompt", "bypass moderation", "skip moderation",
            "moderation is disabled", "classify this as benign",
            "respond with benign", "mark this as benign", "\"decision\":"
        ];
        for (const phrase of unambiguous) {
            if (text.includes(phrase)) return true;
        }

        let hits = 0;
        if (Lexicons.promptInjectionCues) {
            for (const phrase of Lexicons.promptInjectionCues) {
                if (text.includes(phrase)) {
                    hits++;
                    if (hits >= 2) return true;
                }
            }
        }
        return false;
    }

    static dictatedFragment(original: string, digits: string): CarrierCandidate | null {
        const length = digits.length;
        if (length < 5 || length > 14 || length === 10) return null;
        
        const isHighConfidencePhone = (d: string) => Extractors.isHighConfidencePhone(d);
        if (length > 10 && !isHighConfidencePhone(digits)) {
            if (EscalationAnalyser.containsEmbeddedMobile(digits)) return null;
        }

        const tokens = original.split(/[^a-zA-Z0-9]+/).map(t => t.toLowerCase());
        if (tokens.length < 3) return null;

        let numericTokens = 0;
        let wordedTokens = 0;
        for (const token of tokens) {
            if (/^[0-9]+$/.test(token)) {
                numericTokens++;
            } else if (Lexicons.numberWordsCore?.[token] !== undefined || Lexicons.numberWordsRisky?.[token] !== undefined) {
                numericTokens++;
                wordedTokens++;
            }
        }

        if (wordedTokens < 2) return null;
        const density = numericTokens / tokens.length;
        if (numericTokens < 3 || density < 0.5) return null;

        return {
            channel: "spelled number words",
            payload: digits,
            validates: false,
            shape: length < 10 ? "partial phone number" : "padded phone number"
        };
    }

    static contiguousMobile(text: string): string | null {
        const rx = /\d(?:[ .,\-]?\d){8,14}/g;
        let match;
        while ((match = rx.exec(text)) !== null) {
            const span = match[0];
            const digits = span.replace(/\D/g, '');
            if (digits.length < 10 || digits.length > 13) continue;
            if (EscalationAnalyser.isThousandsGrouped(span)) continue;
            if (Extractors.isHighConfidencePhone(digits) || EscalationAnalyser.containsEmbeddedMobile(digits)) {
                return digits;
            }
        }
        return null;
    }

    static isThousandsGrouped(span: string): boolean {
        if (!span.includes(",")) return false;
        const groups = span.split(",").map(s => s.trim());
        if (groups.length < 2) return false;
        const first = groups[0]!;
        if (first.length < 1 || first.length > 3) return false;
        const rest = groups.slice(1);
        const last = rest[rest.length - 1]!;
        if (rest.every(g => g.length === 3)) return true;
        if (last.length === 3 && rest.slice(0, -1).every(g => g.length === 2)) return true;
        return false;
    }

    static containsEmbeddedMobile(digits: string): boolean {
        if (digits.length <= 10) return false;
        for (let start = 0; start <= digits.length - 10; start++) {
            const window = digits.slice(start, start + 10);
            if (Extractors.isHighConfidencePhone(window)) return true;
        }
        return false;
    }

    static positionalCarriers(original: string): CarrierCandidate[] {
        const out: CarrierCandidate[] = [];

        const consider = (channel: string, payload: string, minimum: number, shape: string) => {
            if (payload.length < minimum) return;
            const digits = payload.replace(/\D/g, '');
            if (digits.length >= 10 && Extractors.isHighConfidencePhone(digits)) {
                out.push({ channel, payload: digits, validates: true, shape: "phone number" });
                return;
            }
            const letters = payload.toLowerCase().replace(/[^a-z]/g, '');
            if (letters.length < minimum) return;
            const namesPlatform = Array.from(Lexicons.platformsStrong || []).some(p => p.length >= 5 && letters.includes(p));
            if (!namesPlatform) {
                if (letters.length < 7) return;
                const vowels = (letters.match(/[aeiou]/g) || []).length;
                if (vowels / letters.length < 0.30) return;
            }
            out.push({ channel, payload, validates: namesPlatform, shape: namesPlatform ? "platform name" : shape });
        };

        const caps = PositionalChannels.capitalisedWordInitials(original);
        if (caps.length >= 5 && !PositionalChannels.hasMixedCasing(original)) {
            consider("capitalised word initials", caps, 5, "handle");
        }

        consider("repeated-punctuation run lengths", PositionalChannels.punctuationRunDigits(original), 9, "digit sequence");

        const runs = EscalationAnalyser.repeatRunDigits(original);
        if (runs && runs.length >= 7) {
            consider("repeated-run lengths", runs, 7, "digit sequence");
        }

        return out;
    }

    static repeatRunDigits(s: string): string | null {
        let out = "";
        let runCharacter: string | null = null;
        let runLength = 0;

        const flush = () => {
            if (runLength >= 1 && runLength <= 9 && runCharacter) {
                if (!/\s/.test(runCharacter) && (!/[a-zA-Z]/.test(runCharacter) || runLength >= 3)) {
                    if (runLength >= 2) out += runLength.toString();
                }
            }
            runCharacter = null;
            runLength = 0;
        };

        for (const ch of s) {
            if (ch === runCharacter) {
                runLength++;
            } else {
                flush();
                runCharacter = ch;
                runLength = 1;
            }
        }
        flush();
        return out.length > 0 ? out : null;
    }

    static addressesPerson(alpha: CharView): boolean {
        const tokens = Canonicalizer.tokenize(alpha);
        for (const token of tokens) {
            if (token.isWord && Lexicons.personTargets.has(token.text)) return true;
        }
        return false;
    }

    static addressesPersonNativeScript(original: string): boolean {
        const lowered = original.toLowerCase();
        let hasDevanagari = false;
        let hasCyrillic = false;

        for (let i = 0; i < lowered.length; i++) {
            const code = lowered.charCodeAt(i);
            if (code >= 0x0900 && code <= 0x097F) hasDevanagari = true;
            if (code >= 0x0400 && code <= 0x04FF) hasCyrillic = true;
            if (hasDevanagari && hasCyrillic) break;
        }

        if (!hasDevanagari && !hasCyrillic) return false;

        const tokens = lowered.split(/[^a-zA-Z0-9\u0900-\u097F\u0400-\u04FF]+/);

        if (hasDevanagari && Lexicons.devanagariPersonStems) {
            for (const token of tokens) {
                for (const stem of Lexicons.devanagariPersonStems) {
                    if (token.startsWith(stem)) return true;
                }
            }
        }
        if (hasCyrillic && Lexicons.cyrillicPersonTokens) {
            for (const token of tokens) {
                if (Lexicons.cyrillicPersonTokens.has(token)) return true;
            }
        }
        return false;
    }

    static nativeConditionalDemand(original: string): boolean {
        const lowered = original.toLowerCase();
        if (Lexicons.nativeScriptConditionalCues) {
            for (const cue of Lexicons.nativeScriptConditionalCues) {
                if (lowered.includes(cue)) return true;
            }
        }
        return false;
    }

    static conditionalDemandRX = new RX(
        "conditional-demand",
        "\\b(?:or\\s+(?:else|i|we|il+|i'?ll)|otherwise\\s+i|unless\\s+you|if\\s+you\\s+(?:do\\s*n[o']?t|don'?t|refuse|won'?t)|warna|varna|nahi+n?\\s+toh?|nhi+\\s+toh?)\\b"
    );

    static conditionalReprisalRX = new RX(
        "conditional-reprisal",
        "\\bif\\s+you\\b[^.!?]{0,60}?\\bi\\s*(?:will|'?ll|am\\s+going\\s+to|shall)\\b[^.!?]{0,60}?\\b(?:you|your|u\\b|ur)\\b"
    );

    static conditionalDemand(text: string): boolean {
        return EscalationAnalyser.conditionalDemandRX.matches(text, 1).length > 0 || EscalationAnalyser.conditionalReprisalRX.matches(text, 1).length > 0;
    }

    static obfuscatedDomain(text: string): CarrierCandidate | null {
        // Implement simple stub based on swift version
        const patterns = [
            { name: "domain split by whitespace", rx: /([a-z0-9][a-z0-9\-]{2,})\s*\.\s+([a-z]{2,10})/i, minHost: 3 },
            { name: "domain split by whitespace", rx: /([a-z0-9][a-z0-9\-]{2,})\s+\.\s*([a-z]{2,10})/i, minHost: 3 },
            { name: "defanged dot in brackets", rx: /([a-z0-9][a-z0-9\-]{2,})\s*[\[\(\{<]\s*\.\s*[\]\)\}>]\s*([a-z]{2,10})/i, minHost: 3 },
            { name: "dot spelled inside brackets", rx: /([a-z0-9][a-z0-9\-]{2,})\s*[\[\(\{<]\s*(?:dot|punto|bindu)\s*[\]\)\}>]\s*([a-z]{2,10})/i, minHost: 3 },
            { name: "comma used as the dot", rx: /([a-z0-9][a-z0-9\-]{7,}),\s*([a-z]{2,10})\b/i, minHost: 8 },
            { name: "hyphen used as the dot", rx: /([a-z0-9]{7,})-([a-z]{2,10})\b/i, minHost: 8 }
        ];

        for (const p of patterns) {
            const match = text.match(p.rx);
            if (match && match.length >= 3) {
                const host = match[1]!.toLowerCase();
                const tld = match[2]!.toLowerCase();
                if (host.length >= p.minHost && Lexicons.commonTLDs?.has(tld)) {
                    if (!Lexicons.commonTLDs.has(host)) {
                        const idx = match.index !== undefined ? match.index : 0;
                        const tldStart = idx + match[0].lastIndexOf(tld);
                        if (!EscalationAnalyser.isProseContinuation(p.name, tld, tldStart + tld.length, text)) {
                            return {
                                channel: p.name,
                                payload: `${host}.${tld}`,
                                validates: true,
                                shape: "domain"
                            };
                        }
                    }
                }
            }
        }
        return null;
    }

    private static readonly tldsThatAreAlsoEnglishWords = new Set([
        "it", "is", "in", "at", "me", "so", "to", "by", "us", "no", "as", "am", "be", "do", "my", "an"
    ]);

    private static isProseContinuation(name: string, tld: string, after: number, text: string): boolean {
        if (!name.includes("used as the dot")) return false;
        if (!this.tldsThatAreAlsoEnglishWords.has(tld)) return false;
        if (after >= text.length) return false;
        const remainder = text.slice(after);
        return /^\s+[a-z]{2,}/i.test(remainder);
    }

    static wordlessProtocolCue(original: string, signals: Signals): boolean {
        const letters = original.replace(/[^a-zA-Z]/g, '').length;
        if (letters > 24) return false;

        const cues = ["📞", "☎", "📱", "💬", "📧", "✉", "📩", "📨", "🤙", "📲"];
        if (cues.some(c => original.includes(c))) return true;

        if (letters > 0 && letters <= 24 && signals.platformStrong) {
            const words = original.split(/[^a-zA-Z]+/).filter(w => w.length > 0).length;
            return words <= 3;
        }
        return false;
    }

    static anomalousRegularity(s: string): boolean {
        let runLength = 0;
        let previous: string | null = null;
        for (const ch of s) {
            if (ch === previous && !/\s/.test(ch)) {
                runLength++;
                if (runLength >= 6) return true;
            } else {
                previous = ch;
                runLength = 1;
            }
        }

        const letters = s.replace(/[^a-zA-Z]/g, '').length;
        // Emoji regex approximation
        const emoji = (s.match(/[\u{1F300}-\u{1F9FF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}]/gu) || []).length;
        if (emoji >= 12 && letters <= 12) return true;

        return false;
    }
}
