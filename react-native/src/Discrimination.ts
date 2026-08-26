import { ModCategory } from './ModerationTypes';
import { RX } from './TextPrimitives';
import { SafetyRules, Finding } from './SafetyRules';

export class DiscriminationRules {
    static readonly protectedCharacteristics = new Set([
        "muslim", "muslims", "musalman", "hindu", "hindus", "christian", "christians",
        "sikh", "sikhs", "jain", "jains", "buddhist", "parsi", "jew", "jewish",
        "dalit", "dalits", "harijan", "adivasi", "tribal", "sc", "st", "obc",
        "brahmin", "bania", "chamar", "bhangi", "mahar", "caste", "casteless",
        "lowercaste", "lowcaste", "upper caste", "lower caste", "scheduled caste",
        "bihari", "biharis", "bengali", "bengalis", "madrasi", "marwari", "punjabi",
        "kashmiri", "nepali", "bangladeshi", "pakistani", "african", "nigerian",
        "northeast", "northeastern", "chinki",
        "black", "brown", "white", "dark skinned", "fair skinned",
        "woman", "women", "girls", "single women", "single woman", "lady", "ladies",
        "gay", "lesbian", "queer", "trans", "transgender", "hijra", "lgbt",
        "disabled", "handicapped", "blind", "deaf", "wheelchair",
        "bachelor", "bachelors", "unmarried", "unmarried couple", "unmarried couples",
        "foreigner", "foreigners",
        "musalmaan", "isai", "bangali"
    ]);

    private static readonly refusalRX = new RX(
        "discrimination-refusal",
        "(?:no|not?\\s+for|don'?t|do\\s+not|won'?t|cannot|can'?t|never)\\s+(?:rent|let|allow|accept|take|host|entertain|give|book)[^.!?]{0,30}?(?:to\\s+)?"
    );

    private static readonly onlyRX = new RX(
        "discrimination-only",
        "(?:only|strictly)\\s+(?:for\\s+)?(?:[a-z]+\\s+){0,2}(?:families|vegetarian|vegetarians)?"
    );

    private static readonly notAllowedRX = new RX(
        "discrimination-not-allowed",
        "(?:are|is)\\s+not\\s+(?:allowed|permitted|welcome|accepted)"
    );

    private static readonly prefixRX = new RX(
        "discrimination-prefix",
        "\\bno\\s+(?:[a-z]+\\s+){0,2}(?:allowed|permitted|please)?"
    );

    static refusal(text: string): Finding | null {
        const lower = text.toLowerCase();
        const words = lower.split(/[^a-zA-Z0-9]+/).filter(w => w.length > 0);

        let characteristic: string | undefined = words.find(w => this.protectedCharacteristics.has(w));
        if (!characteristic) characteristic = this.twoWordCharacteristic(lower);
        if (!characteristic) return null;

        const constructions = [this.refusalRX, this.notAllowedRX, this.onlyRX, this.prefixRX];
        for (const rx of constructions) {
            for (const match of rx.matches(lower, 4)) {
                const charIdx = lower.indexOf(characteristic);
                if (charIdx === -1) continue;
                const distance = Math.abs(charIdx - match.end);
                if (distance <= 24) {
                    return {
                        category: ModCategory.Discrimination,
                        confidence: 0.88,
                        phrase: `service conditioned on a protected characteristic (${characteristic})`,
                        range: [0, Math.max(1, text.length)],
                        target: "group"
                    };
                }
            }
        }
        return null;
    }

    private static twoWordCharacteristic(lower: string): string | undefined {
        for (const term of this.protectedCharacteristics) {
            if (term.includes(" ") && lower.includes(term)) return term;
        }
        return undefined;
    }
}

export class Discrimination {
    static discrimination(base: import('./Canonicalizer').CharView, original: string): Finding | null {
        const text = original.length > 0 ? original : base.text;
        return DiscriminationRules.refusal(text);
    }
}
