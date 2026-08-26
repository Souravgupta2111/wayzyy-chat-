import { Lexicons } from './Lexicons';
import { HinglishFold } from './LanguageFolding';
import { platform } from './Platform';

export class SlurLexicon {
    private static skeletons: Set<string> = new Set();
    private static loaded = false;

    private static readonly seed: string[] = [
        "chamar", "bhangi", "chuhra", "mahar", "dhed", "neech jaat", "neechjaat",
        "katua", "mulla", "landya", "kaffir",
        "chinki", "chinky", "madrasi", "bhaiya log", "bihari kutta",
        "habshi", "kalu", "negro",
        "langda", "andha kutta", "retard", "retarded",
        "chhakka", "gandu chhakka", "faggot", "tranny",
    ];

    /**
     * Install terms directly (Expo app: pass the parsed contents of the bundled
     * or remotely-fetched slurs.json here instead of relying on a filesystem).
     */
    static loadFromTerms(terms: Iterable<string>): Set<string> {
        const normalised = new Set(Array.from(terms).map(t => t.toLowerCase()));
        Lexicons.slurTerms = normalised;
        this.skeletons = HinglishFold.skeletonSet(normalised);
        this.loaded = true;
        return normalised;
    }

    static load(): Set<string> {
        const terms = new Set(this.seed);

        const candidates: string[] = [];
        const envPath = platform().env("WAYZYY_SLUR_LEXICON");
        if (envPath) candidates.push(envPath);
        candidates.push("config/slurs.json");

        for (const p of candidates) {
            const raw = platform().readTextFile(p);
            if (raw === null) continue;
            let merged = false;
            try {
                const list = JSON.parse(raw);
                if (Array.isArray(list)) {
                    for (const t of list) if (typeof t === 'string') terms.add(t);
                    merged = true;
                }
            } catch {
                const lines = raw
                    .split(/\r?\n/)
                    .map(l => l.trim())
                    .filter(l => l.length > 0 && !l.startsWith('#'));
                if (lines.length > 0) {
                    for (const l of lines) terms.add(l);
                    merged = true;
                }
            }
            if (merged) break;
        }

        return this.loadFromTerms(terms);
    }

    static get termCount(): number {
        return Lexicons.slurTerms.size;
    }

    static matchesSkeleton(skeletonWords: Set<string>): boolean {
        if (this.skeletons.size === 0) return false;
        for (const w of skeletonWords) {
            if (this.skeletons.has(w)) return true;
        }
        return false;
    }

    private static bootstrapped = false;
    static bootstrap(): void {
        if (this.bootstrapped) return;
        this.bootstrapped = true;
        this.load();
    }
}
