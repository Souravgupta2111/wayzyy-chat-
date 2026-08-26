import { CharView, Canonicalizer } from './Canonicalizer';
import { Detection } from './ModerationTypes';
import { Lexicons } from './Lexicons';

export class Signals {
    hasContactIntent: boolean = false;
    contactIntentPhrase: string | null = null;
    platformStrong: boolean = false;
    platformWeak: boolean = false;
    platformName: string | null = null;
    offPlatformIntent: boolean = false;
    offPlatformPhrase: string | null = null;
    paymentKeyword: boolean = false;
    mailKeyword: boolean = false;
    digitsEmbeddedInWords: number = 0;
    explicitAtCount: number = 0;
    digitCount: number = 0;
    characterCount: number = 0;

    get digitDensity(): number {
        return this.characterCount === 0 ? 0 : this.digitCount / this.characterCount;
    }

    static compute(base: CharView, alpha: CharView, compact: CharView): Signals {
        const s = new Signals();
        const text = base.text;
        
        // This is a rough translation of `alpha.filtering("x") { $0.isLetter }.text`
        // We'll need a proper filtering method on CharView later, but for now we regex it.
        const alphaCompactText = alpha.text.replace(/[^a-zA-Z]/g, '');

        s.characterCount = base.count;
        s.digitCount = (base.text.match(/[0-9]/g) || []).length;
        s.explicitAtCount = (base.text.match(/@/g) || []).length;

        for (const phrase of Lexicons.contactIntent) {
            if (text.includes(phrase)) {
                s.hasContactIntent = true;
                s.contactIntentPhrase = phrase;
                break;
            }
        }

        for (const phrase of Lexicons.offPlatformIntent) {
            if (text.includes(phrase)) {
                s.offPlatformIntent = true;
                s.offPlatformPhrase = phrase;
                break;
            }
        }

        const tokens = Canonicalizer.tokenize(alpha);
        for (const token of tokens) {
            if (!token.isWord) continue;
            const t = token.text;

            if (Lexicons.platformsStrong.has(t)) {
                s.platformStrong = true;
                s.platformName = t;
            } else if (Lexicons.platformsWeak.has(t)) {
                s.platformWeak = true;
                if (!s.platformName) s.platformName = t;
            }
            if (Lexicons.paymentKeywords.has(t)) {
                s.paymentKeyword = true;
            }
            if (["mail", "email", "emailid", "gmail", "inbox", "id", "address",
                "yahoo", "outlook", "hotmail", "icloud", "protonmail"].includes(t)) {
                s.mailKeyword = true;
            }
        }

        if (!s.platformStrong && Lexicons.platformsStrong) {
            const compactText = compact.text;
            for (const p of Lexicons.platformsStrong) {
                if (p.length >= 5 && compactText.includes(p)) {
                    s.platformStrong = true;
                    s.platformName = p;
                    break;
                }
            }
        }

        if (!s.mailKeyword) {
            for (const kw of ["gmail", "email", "mailid", "emailid"]) {
                if (alphaCompactText.includes(kw)) {
                    s.mailKeyword = true;
                    break;
                }
            }
        }

        for (const token of tokens) {
            if (!token.isWord) continue;
            const t = token.text;
            if (t.length < 3) continue;

            const letters = (t.match(/[a-zA-Z]/g) || []).length;
            const digits = (t.match(/[0-9]/g) || []).length;
            const allDigits = /^[0-9]+$/.test(t);

            if (letters >= 2 && digits >= 1 && !allDigits) {
                s.digitsEmbeddedInWords += 1;
            }
        }

        return s;
    }
}

export class ScorerWeights {
    bias: number = -3.55;
    maxConfidence: number = 4.30;
    detectionCount: number = 0.34;
    obfuscationEffort: number = 2.45;
    contactIntent: number = 1.52;
    platformStrong: number = 1.02;
    platformWeak: number = 0.42;
    offPlatformIntent: number = 1.34;
    paymentKeyword: number = 0.58;
    digitsEmbedded: number = 1.14;
    suppressedOnly: number = -1.62;
    crossMessage: number = 1.70;
    priorViolations: number = 0.82;
    explicitAt: number = 0.46;
    digitDensity: number = 0.70;

    static readonly default = new ScorerWeights();
}

export interface ScorerInput {
    detections: Detection[];
    signals: Signals;
    obfuscationEffort: number;
    suppressedOnly: boolean;
    crossMessageAssembled: boolean;
    priorViolations: number;
}

export interface ScorerOutput {
    score: number;
    features: [string, number][];
    contributions: [string, number][];
}

export class Scorer {
    weights: ScorerWeights;

    constructor(weights: ScorerWeights = ScorerWeights.default) {
        this.weights = weights;
    }

    score(input: ScorerInput): ScorerOutput {
        const w = this.weights;
        const s = input.signals;

        const confidences = input.detections.map(d => d.confidence);
        const maxConf = confidences.length > 0 ? Math.max(...confidences) : 0;
        
        const countNorm = Math.min(input.detections.length, 3.0) / 3.0;
        const effortNorm = Math.min(input.obfuscationEffort, 12.0) / 12.0;
        const embeddedNorm = Math.min(s.digitsEmbeddedInWords, 3.0) / 3.0;
        const atNorm = Math.min(s.explicitAtCount, 2.0) / 2.0;
        const priorNorm = Math.min(input.priorViolations, 3.0) / 3.0;
        const densityNorm = Math.min(s.digitDensity * 3.0, 1.0);

        const terms: [string, number, number][] = [
            ["bias", 1, w.bias],
            ["candidate confidence", maxConf, w.maxConfidence],
            ["candidate count", countNorm, w.detectionCount],
            ["obfuscation effort", effortNorm, w.obfuscationEffort],
            ["contact-intent phrase", s.hasContactIntent ? 1 : 0, w.contactIntent],
            ["platform keyword (strong)", s.platformStrong ? 1 : 0, w.platformStrong],
            ["platform keyword (weak)", s.platformWeak ? 1 : 0, w.platformWeak],
            ["off-platform framing", s.offPlatformIntent ? 1 : 0, w.offPlatformIntent],
            ["payment keyword", s.paymentKeyword ? 1 : 0, w.paymentKeyword],
            ["digits inside words", embeddedNorm, w.digitsEmbedded],
            ["legit numeric context", input.suppressedOnly ? 1 : 0, w.suppressedOnly],
            ["assembled across messages", input.crossMessageAssembled ? 1 : 0, w.crossMessage],
            ["prior violations", priorNorm, w.priorViolations],
            ["explicit @", atNorm, w.explicitAt],
            ["digit density", densityNorm, w.digitDensity],
        ];

        let logit = 0.0;
        const features: [string, number][] = [];
        const contributions: [string, number][] = [];

        for (const [name, value, weight] of terms) {
            const contribution = value * weight;
            logit += contribution;
            if (name !== "bias") {
                features.push([name, value]);
            }
            if (Math.abs(contribution) > 0.001) {
                contributions.push([name, contribution]);
            }
        }

        const probability = 1.0 / (1.0 + Math.exp(-logit));
        
        contributions.sort((a, b) => Math.abs(b[1]) - Math.abs(a[1]));

        return {
            score: probability,
            features,
            contributions
        };
    }
}
