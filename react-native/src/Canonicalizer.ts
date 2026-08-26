import { Lexicons } from './Lexicons';
import { CharView } from './TextPrimitives';
import { HinglishFold } from './LanguageFolding';
import { NumericContext } from './NumericContext';

export { CharView } from './TextPrimitives';

export interface ViewToken {
    text: string;
    start: number;
    end: number;
    isWord: boolean;
}

export interface CanonicalizerViews {
    raw: CharView;
    base: CharView;
    alpha: CharView;
    compact: CharView;
    alphaCompact: CharView;
    digits: CharView;
    digitsMasked: CharView;
    digitsReversed: CharView;
    separators: CharView;
    separatorsAlt: CharView;
    acrostic: CharView;
    compactDigits: CharView;
    romanDigits: CharView;
    devanagariLatin: CharView;
    hinglishSkeleton: CharView;
    allTransforms: string[];
}

export class Canonicalizer {
    static readonly deliberateTransforms = new Set([
        "confusable-fold", "invisible-strip", "compat-fold", "emoji-digit",
        "number-words", "repeat-collapse", "nato-letters", "conversation-buffer",
        "morse-decode", "binary-decode", "hex-decode", "base64-decode", "rot13-decode",
        "percent-decode", "digit-script-fold", "numeral-script-fold",
        "hidden-carrier-decode", "roman-numerals",
        "positional-channel", "protocol-establishment",
        "separator-words", "spelled-separators",
    ]);

    static effortWeight(transform: string): number {
        switch (transform) {
            case "confusable-fold":
            case "invisible-strip":
            case "emoji-digit": return 4;
            case "morse-decode":
            case "binary-decode":
            case "hex-decode":
            case "base64-decode":
            case "rot13-decode":
            case "percent-decode": return 4;
            case "hidden-carrier-decode": return 5;
            case "positional-channel":
            case "protocol-establishment": return 4;
            case "digit-script-fold":
            case "numeral-script-fold": return 4;
            case "number-words":
            case "nato-letters":
            case "conversation-buffer": return 3;
            case "compat-fold":
            case "roman-numerals": return 3;
            case "separator-words":
            case "spelled-separators": return 3;
            case "repeat-collapse": return 1;
            default: return 0;
        }
    }

    static effort(transforms: string[]): number {
        return transforms
            .filter(t => this.deliberateTransforms.has(t))
            .reduce((sum, t) => sum + this.effortWeight(t), 0);
    }

    static compatibilityFold(ch: string): string {
        const cp = ch.codePointAt(0);
        if (cp !== undefined && ch.length === 1) {
            const multi = Lexicons.compatibilityFallbackString(cp);
            if (multi !== null) return multi;
        }
        return ch.normalize("NFKC");
    }

    static tagCharacter(codePoint: number): string | null {
        if (codePoint < 0xE0020 || codePoint > 0xE007E) return null;
        return String.fromCodePoint(codePoint - 0xE0000);
    }

    static regionalIndicatorLetter(codePoint: number): string | null {
        if (codePoint < 0x1F1E6 || codePoint > 0x1F1FF) return null;
        return String.fromCharCode(97 + (codePoint - 0x1F1E6));
    }

    static diacriticAndCaseFold(ch: string): string {
        return ch
            .normalize("NFD")
            .replace(/[\u0300-\u036f\u1ab0-\u1aff\u20d0-\u20ff\ufe20-\ufe2f]/g, "")
            .toLowerCase();
    }

    static enclosedDigit(ch: string): string | null {
        const v = ch.codePointAt(0);
        if (v === undefined) return null;
        if (v >= 0x2460 && v <= 0x2468) return String(v - 0x2460 + 1);
        if (v === 0x24EA) return "0";
        if (v >= 0x2775 && v <= 0x277D) return String(v - 0x2775 + 1);
        if (v === 0x1F10B) return "0";
        return null;
    }

    static tokenize(view: CharView): ViewToken[] {
        const tokens: ViewToken[] = [];
        let i = 0;
        const chars = view.chars;
        
        while (i < chars.length) {
            const ch = chars[i];
            if (/\p{L}|\p{N}|\p{M}/u.test(ch)) {
                let j = i;
                while (j < chars.length && /(\p{L}|\p{N}|\p{M})/u.test(chars[j])) {
                    j++;
                }
                tokens.push({ text: chars.slice(i, j).join(''), start: i, end: j, isWord: true });
                i = j;
            } else {
                tokens.push({ text: ch, start: i, end: i + 1, isWord: false });
                i++;
            }
        }
        return tokens;
    }

    private static collapseRepeats(view: CharView): CharView {
        const outChars: string[] = [];
        const outOffsets: number[] = [];
        let run = 0;
        let last: string | null = null;
        let changed = false;

        for (let i = 0; i < view.chars.length; i++) {
            const ch = view.chars[i];
            if (ch === last) {
                run++;
            } else {
                run = 1;
                last = ch;
            }
            if (run <= 2) {
                outChars.push(ch);
                outOffsets.push(view.offsets[i]);
            } else {
                changed = true;
            }
        }

        return new CharView(
            outChars,
            outOffsets,
            changed ? [...view.transforms, "repeat-collapse"] : view.transforms
        );
    }

    static leetFoldToken(t: string): string {
        if (!/\d/.test(t) || !/[a-zA-Z]/.test(t)) return "";
        return Array.from(t).map(ch => Lexicons.leetToLetter[ch] || ch).join('');
    }

    static segmentNumberWords(token: string, minMatches: number = 3): string | null {
        if (token.length < 4 || !/^[a-zA-Z]+$/.test(token)) return null;
        const chars = Array.from(token);
        const n = chars.length;

        const matchAt = (i: number): { digits: string, length: number } | null => {
            for (let len = Math.min(9, n - i); len >= 3; len--) {
                const substr = chars.slice(i, i + len).join('');
                if (Lexicons.numberWordsCore && (substr in Lexicons.numberWordsCore)) {
                    return { digits: Lexicons.numberWordsCore[substr]!, length: len };
                }
            }
            return null;
        };

        let bestDigits = "";
        let bestMatches = 0;
        let runDigits = "";
        let runMatches = 0;
        let i = 0;

        while (i < n) {
            const hit = matchAt(i);
            if (hit) {
                runDigits += hit.digits;
                runMatches += 1;
                i += hit.length;
            } else {
                if (runMatches > bestMatches) {
                    bestMatches = runMatches;
                    bestDigits = runDigits;
                }
                runDigits = "";
                runMatches = 0;
                i += 1;
            }
        }
        if (runMatches > bestMatches) {
            bestMatches = runMatches;
            bestDigits = runDigits;
        }

        return bestMatches >= minMatches ? bestDigits : null;
    }

    static segmentMixedToken(token: string): string | null {
        if (token.length < 6) return null;
        const hasLetter = /[a-zA-Z]/.test(token);
        const hasDigit = /\d/.test(token);
        if (!hasLetter || !hasDigit) return null;

        let out = "";
        let buffer = "";
        let wordMatches = 0;

        const flushLetters = (): boolean => {
            if (!buffer) return true;
            if (Lexicons.numberWordsCore && (buffer in Lexicons.numberWordsCore)) {
                out += Lexicons.numberWordsCore[buffer]!;
                wordMatches++;
            } else if (Lexicons.numberWordsRisky && (buffer in Lexicons.numberWordsRisky)) {
                out += Lexicons.numberWordsRisky[buffer]!;
                wordMatches++;
            } else {
                const segments = this.segmentNumberWords(buffer, 1);
                if (segments) {
                    out += segments;
                    wordMatches++;
                } else {
                    return false;
                }
            }
            buffer = "";
            return true;
        };

        for (const ch of token) {
            if (/\d/.test(ch)) {
                if (!flushLetters()) return null;
                out += ch;
            } else if (/[a-zA-Z]/.test(ch)) {
                buffer += ch;
            } else {
                return null;
            }
        }
        if (!flushLetters()) return null;
        return wordMatches >= 1 ? out : null;
    }

    static expandNumberWords(view: CharView): CharView {
        const tokens = this.tokenize(view);
        if (tokens.length === 0) return view;

        enum ResType { none, core, risky, homophone, fuzzy, modifier }
        const resolutions: { type: ResType, val?: string | number }[] = Array(tokens.length).fill({ type: ResType.none });

        for (let idx = 0; idx < tokens.length; idx++) {
            const token = tokens[idx];
            if (!token.isWord) continue;
            const t = token.text;

            if (Lexicons.repeatModifiers && (t in Lexicons.repeatModifiers)) resolutions[idx] = { type: ResType.modifier, val: Lexicons.repeatModifiers[t] };
            else if (Lexicons.numberWordsCore && (t in Lexicons.numberWordsCore)) resolutions[idx] = { type: ResType.core, val: Lexicons.numberWordsCore[t] };
            else if (Lexicons.numberWordsRisky && (t in Lexicons.numberWordsRisky)) resolutions[idx] = { type: ResType.risky, val: Lexicons.numberWordsRisky[t] };
            else if (Lexicons.numberWordsIndic && (t in Lexicons.numberWordsIndic)) resolutions[idx] = { type: ResType.risky, val: Lexicons.numberWordsIndic[t] };
            else if (Lexicons.numberWordsHomophones && (t in Lexicons.numberWordsHomophones)) resolutions[idx] = { type: ResType.homophone, val: Lexicons.numberWordsHomophones[t] };
            else if (Lexicons.numberWordsIndicAmbiguous && (t in Lexicons.numberWordsIndicAmbiguous)) resolutions[idx] = { type: ResType.homophone, val: Lexicons.numberWordsIndicAmbiguous[t] };
            else if (Lexicons.numberWordsFunctionWords && (t in Lexicons.numberWordsFunctionWords)) resolutions[idx] = { type: ResType.fuzzy, val: Lexicons.numberWordsFunctionWords[t] };
            else if (Lexicons.numberWordsCore && (this.leetFoldToken(t) in Lexicons.numberWordsCore)) resolutions[idx] = { type: ResType.core, val: Lexicons.numberWordsCore[this.leetFoldToken(t)] };
            else {
                const fuzzy = Lexicons.fuzzyNumberWord(t);
                if (fuzzy) resolutions[idx] = { type: ResType.fuzzy, val: fuzzy };
                else {
                    const segments = this.segmentNumberWords(t);
                    if (segments) resolutions[idx] = { type: ResType.core, val: segments };
                    else {
                        const mixed = this.segmentMixedToken(t);
                        if (mixed) resolutions[idx] = { type: ResType.core, val: mixed };
                    }
                }
            }
        }

        const isNumericish = (i: number): boolean => {
            if (i < 0 || i >= tokens.length || !tokens[i].isWord) return false;
            const res = resolutions[i];
            if (res.type !== ResType.none) return true;
            return /^\d+$/.test(tokens[i].text);
        };

        const isSpelled = (i: number): boolean => {
            if (i < 0 || i >= tokens.length || !tokens[i].isWord) return false;
            const t = resolutions[i].type;
            return t === ResType.core || t === ResType.risky || t === ResType.homophone || t === ResType.fuzzy;
        };

        const neighbours = (i: number): [number, number] => {
            let l = i - 1;
            while (l >= 0 && !tokens[l].isWord) l--;
            let r = i + 1;
            while (r < tokens.length && !tokens[r].isWord) r++;
            return [l, r];
        };

        const hasNumericNeighbour = (i: number): boolean => {
            const [l, r] = neighbours(i);
            return isNumericish(l) || isNumericish(r);
        };

        const hasSpelledNeighbour = (i: number): boolean => {
            const [l, r] = neighbours(i);
            return isSpelled(l) || isSpelled(r);
        };

        const isInsideDictation = (i: number): boolean => {
            const [l, r] = neighbours(i);
            if (isSpelled(l) || isSpelled(r)) return true;
            const sides = [l, r].filter(x => x >= 0 && x < tokens.length);
            if (sides.length === 0) return false;
            return sides.every(isNumericish);
        };

        const promoted: (string | null)[] = Array(tokens.length).fill(null);

        for (let idx = 0; idx < resolutions.length; idx++) {
            const res = resolutions[idx];
            if (res.type === ResType.core) promoted[idx] = res.val as string;
            else if (res.type === ResType.risky && hasNumericNeighbour(idx)) promoted[idx] = res.val as string;
            else if (res.type === ResType.homophone && isInsideDictation(idx)) promoted[idx] = res.val as string;
            else if (res.type === ResType.fuzzy && hasSpelledNeighbour(idx)) promoted[idx] = res.val as string;
        }

        for (let idx = 0; idx < resolutions.length; idx++) {
            const res = resolutions[idx];
            if (res.type !== ResType.modifier) continue;
            const mult = res.val as number;
            let r = idx + 1;
            while (r < tokens.length && !tokens[r].isWord) r++;
            if (r >= tokens.length) continue;

            let following: string | null = null;
            if (promoted[r]) following = promoted[r];
            else if (/^\d+$/.test(tokens[r].text)) following = tokens[r].text;

            if (following && following.length === 1) {
                promoted[r] = following.repeat(mult);
                promoted[idx] = "";
            }
        }

        const outChars: string[] = [];
        const outOffsets: number[] = [];
        let changed = false;

        for (let idx = 0; idx < tokens.length; idx++) {
            const token = tokens[idx];
            const replacement = promoted[idx];
            if (replacement !== null) {
                changed = true;
                const origin = view.offsets[token.start];
                for (const rc of replacement) {
                    outChars.push(rc);
                    outOffsets.push(origin);
                }
            } else {
                for (let k = token.start; k < token.end; k++) {
                    outChars.push(view.chars[k]);
                    outOffsets.push(view.offsets[k]);
                }
            }
        }

        return new CharView(
            outChars,
            outOffsets,
            changed ? [...view.transforms, "number-words"] : view.transforms
        );
    }

    static expandRomanNumerals(view: CharView): CharView {
        const tokens = this.tokenize(view);
        const romanChars = new Set("ivxlcdm");

        const resolved: (string | null)[] = Array(tokens.length).fill(null);
        let runLength = 0;

        for (let idx = 0; idx < tokens.length; idx++) {
            const token = tokens[idx];
            if (!token.isWord) continue;
            const t = token.text;
            if (t.length > 0 && Array.from(t).every(c => romanChars.has(c))) {
                let digits: string | null = null;
                for (const [numeral, val] of Lexicons.romanNumerals || []) {
                    if (numeral === t) {
                        digits = val;
                        break;
                    }
                }
                if (digits) {
                    resolved[idx] = digits;
                    runLength++;
                }
            }
        }

        if (runLength < 4) return view;

        const outChars: string[] = [];
        const outOffsets: number[] = [];
        for (let idx = 0; idx < tokens.length; idx++) {
            const token = tokens[idx];
            const replacement = resolved[idx];
            if (replacement !== null) {
                const origin = view.offsets[token.start];
                for (const rc of replacement) {
                    outChars.push(rc);
                    outOffsets.push(origin);
                }
            } else {
                for (let k = token.start; k < token.end; k++) {
                    outChars.push(view.chars[k]);
                    outOffsets.push(view.offsets[k]);
                }
            }
        }

        return new CharView(
            outChars,
            outOffsets,
            [...view.transforms, "roman-numerals"]
        );
    }

    static expandSeparatorWords(view: CharView): CharView {
        const tokens = this.tokenize(view);
        const outChars: string[] = [];
        const outOffsets: number[] = [];
        let changed = false;

        const wordNeighbour = (i: number, dir: number): boolean => {
            let k = i + dir;
            while (k >= 0 && k < tokens.length && !tokens[k].isWord) {
                const t = tokens[k].text;
                if (t.length > 0 && t[0].trim() && !"()[]{}".includes(t[0])) {
                    return false;
                }
                k += dir;
            }
            if (k >= 0 && k < tokens.length && tokens[k].isWord) {
                const t = tokens[k].text;
                return t.length >= 1 && /[a-zA-Z0-9]/.test(t[0]);
            }
            return false;
        };

        let skipNextWhitespace = false;
        for (let idx = 0; idx < tokens.length; idx++) {
            const token = tokens[idx];
            if (skipNextWhitespace && token.text.trim() === "") {
                skipNextWhitespace = false;
                continue;
            }
            skipNextWhitespace = false;
            
            if (token.isWord && Lexicons.separatorWords && (token.text in Lexicons.separatorWords) && wordNeighbour(idx, -1) && wordNeighbour(idx, 1)) {
                changed = true;
                while (outChars.length > 0 && outChars[outChars.length - 1].trim() === "") {
                    outChars.pop();
                    outOffsets.pop();
                }
                const origin = view.offsets[token.start];
                const symbol = Lexicons.separatorWords[token.text]!;
                for (const rc of symbol) {
                    outChars.push(rc);
                    outOffsets.push(origin);
                }
                skipNextWhitespace = true;
            } else {
                for (let k = token.start; k < token.end; k++) {
                    outChars.push(view.chars[k]);
                    outOffsets.push(view.offsets[k]);
                }
            }
        }

        const joined = new CharView(
            outChars,
            outOffsets,
            changed ? [...view.transforms, "separator-words"] : view.transforms
        );

        const unbracketed = joined.filtering("bracket-strip", ch => !"[](){}<>".includes(ch));
        const sepSymbols = new Set(["@", ".", "_", "-", "/", ":", "+"]);
        const chars = unbracketed.chars;
        const keep = Array(chars.length).fill(true);

        for (let i = 0; i < chars.length; i++) {
            if (chars[i].trim() === "") {
                let p = i - 1;
                while (p >= 0 && chars[p].trim() === "") p--;
                let n = i + 1;
                while (n < chars.length && chars[n].trim() === "") n++;

                const prevIsSep = p >= 0 && sepSymbols.has(chars[p]);
                const nextIsSep = n < chars.length && sepSymbols.has(chars[n]);
                if (prevIsSep || nextIsSep) keep[i] = false;
            }
        }

        const finalChars: string[] = [];
        const finalOffsets: number[] = [];
        for (let i = 0; i < chars.length; i++) {
            if (keep[i]) {
                finalChars.push(chars[i]);
                finalOffsets.push(unbracketed.offsets[i]);
            }
        }

        return new CharView(
            finalChars,
            finalOffsets,
            unbracketed.transforms
        );
    }

    static buildAcrostic(view: CharView): CharView {
        const outChars: string[] = [];
        const outOffsets: number[] = [];

        const tokens = this.tokenize(view);
        for (const token of tokens) {
            if (token.isWord) {
                outChars.push(view.chars[token.start]);
                outOffsets.push(view.offsets[token.start]);
            }
        }

        return new CharView(outChars, outOffsets, [...view.transforms, "acrostic"]);
    }
    
    static buildHinglishSkeleton(view: CharView): CharView {
        const outChars: string[] = [];
        const outOffsets: number[] = [];
        let changed = false;

        let wordChars: string[] = [];
        let wordOffsets: number[] = [];

        const flushWord = () => {
            if (wordChars.length === 0) return;
            const folded = HinglishFold.skeleton(wordChars.join(''));
            if (folded.length !== wordChars.length) changed = true;
            
            const origin = wordOffsets.length > 0 ? wordOffsets[0] : 0;
            for (const c of folded) {
                outChars.push(c);
                outOffsets.push(origin);
            }
            wordChars = [];
            wordOffsets = [];
        };

        for (let i = 0; i < view.chars.length; i++) {
            const ch = view.chars[i];
            if (/[a-zA-Z0-9]/.test(ch)) {
                wordChars.push(ch);
                wordOffsets.push(view.offsets[i]);
            } else {
                flushWord();
                outChars.push(" ");
                outOffsets.push(view.offsets[i]);
            }
        }
        flushWord();

        return new CharView(
            outChars,
            outOffsets,
            changed ? [...view.transforms, "hinglish-skeleton"] : view.transforms
        );
    }

    build(original: string): CanonicalizerViews {
        const raw = CharView.fromString(original);

        const compat = raw.mapping("compat-fold", ch => {
            const folded = Canonicalizer.compatibilityFold(ch);
            return folded ? folded : null;
        });

        const decoded = compat.mapping("hidden-carrier-decode", ch => {
            const cps = Array.from(ch).map(c => c.codePointAt(0)!);
            if (cps.length === 1) {
                const tag = Canonicalizer.tagCharacter(cps[0]!);
                if (tag) return tag;
                const ri = Canonicalizer.regionalIndicatorLetter(cps[0]!);
                if (ri) return ri;
            }
            let out = "";
            let decodedAny = false;
            for (const cp of cps) {
                const tag = Canonicalizer.tagCharacter(cp);
                if (tag) { out += tag; decodedAny = true; continue; }
                const ri = Canonicalizer.regionalIndicatorLetter(cp);
                if (ri) { out += ri; decodedAny = true; continue; }
                out += String.fromCodePoint(cp);
            }
            return decodedAny ? out : ch;
        });

        const visible = decoded.mapping("invisible-strip", ch => {
            const cps = Array.from(ch);
            const kept = cps.filter(c => !(Lexicons.invisibleScalars && Lexicons.invisibleScalars.has(c.codePointAt(0)!)));
            if (kept.length === 0) return null;
            if (kept.length === cps.length) return ch;
            return kept.join("");
        });

        const deEmoji = visible.mapping("emoji-digit", ch => {
            const d = Canonicalizer.enclosedDigit(ch);
            return d ? d : ch;
        });

        const asciiDigits = deEmoji.mapping("digit-script-fold", ch => {
            const cp = ch.codePointAt(0);
            if (cp !== undefined && cp > 127) {
                const digitBlocks: [number, number][] = [
                    [0x0660, 0x0669], // Eastern Arabic
                    [0x06F0, 0x06F9], // Persian/Urdu
                    [0x07C0, 0x07C9], // Nko
                    [0x0966, 0x096F], // Devanagari
                    [0x09E6, 0x09EF], // Bengali
                    [0x0A66, 0x0A6F], // Gurmukhi
                    [0x0AE6, 0x0AEF], // Gujarati
                    [0x0B66, 0x0B6F], // Oriya
                    [0x0BE6, 0x0BEF], // Tamil
                    [0x0C66, 0x0C6F], // Telugu
                    [0x0CE6, 0x0CEF], // Kannada
                    [0x0D66, 0x0D6F], // Malayalam
                    [0x0DE6, 0x0DEF], // Sinhala
                    [0x0E50, 0x0E59], // Thai
                    [0x0ED0, 0x0ED9], // Lao
                    [0x0F20, 0x0F29], // Tibetan
                    [0x1040, 0x1049], // Myanmar
                    [0x1090, 0x1099], // Myanmar Shan
                    [0x17E0, 0x17E9], // Khmer
                    [0x1810, 0x1819], // Mongolian
                    [0x1946, 0x194F], // Limbu
                    [0x19D0, 0x19D9], // New Tai Lue
                    [0x1B50, 0x1B59], // Balinese
                    [0x1BB0, 0x1BB9], // Sundanese
                    [0x1C40, 0x1C49], // Lepcha
                    [0x1C50, 0x1C59], // Ol Chiki
                    [0xA900, 0xA909], // Kayah Li
                    [0xA9D0, 0xA9D9], // Javanese
                    [0xAA50, 0xAA59], // Cham
                    [0xABF0, 0xABF9], // Meetei Mayek
                    [0xFF10, 0xFF19], // Fullwidth
                ];
                for (const [lo, hi] of digitBlocks) {
                    if (cp >= lo && cp <= hi) return String(cp - lo);
                }
                if (/^\p{Nd}$/u.test(ch)) {
                    for (let i = 0; i <= 9; i++) {
                        if (ch.normalize('NFKC') === String(i)) return String(i);
                    }
                }
            }
            return ch;
        });

        const scriptNumerals = asciiDigits.mapping("numeral-script-fold", ch => {
            if (Lexicons.hanNumerals && (ch in Lexicons.hanNumerals)) return Lexicons.hanNumerals[ch]!;
            if (Lexicons.brailleDigits && (ch in Lexicons.brailleDigits)) return Lexicons.brailleDigits[ch]!;
            return ch;
        });

        const deConfused = scriptNumerals.mapping("confusable-fold", ch => {
            if (ch in Lexicons.confusables) {
                return Lexicons.confusables[ch];
            }
            const lower = ch.toLowerCase();
            if (Lexicons.confusables && (lower in Lexicons.confusables)) return Lexicons.confusables[lower]!;
            return ch;
        });

        const normalized = deConfused.mapping("case-fold", ch => {
            const s = Canonicalizer.diacriticAndCaseFold(ch);
            return s ? s : null;
        });

        const base = Canonicalizer.collapseRepeats(normalized);

        const alpha = base.mapping("leet-fold", ch => {
            if (ch in Lexicons.leetToLetter) {
                return Lexicons.leetToLetter[ch];
            }
            return ch;
        });

        const compact = base.filtering("compact", ch => /[\p{L}\p{N}\p{M}]/u.test(ch));
        const alphaCompact = alpha.filtering("compact", ch => /[\p{L}\p{N}\p{M}]/u.test(ch));

        const worded = Canonicalizer.expandNumberWords(base);
        const digits = worded.filtering("digits-only", ch => /\d/.test(ch));

        const contextMasked = NumericContext.mask(base);
        const maskedWorded = Canonicalizer.expandNumberWords(contextMasked);
        const digitsMasked = maskedWorded.filtering("digits-only", ch => /\d/.test(ch));

        const digitsReversed = new CharView(
            [...digits.chars].reverse(),
            [...digits.offsets].reverse(),
            [...digits.transforms, "reverse"]
        );

        const separators = Canonicalizer.expandSeparatorWords(base);
        const separatorsAlt = separators.mapping("underscore-as-dot", ch => ch === "_" ? "." : ch);
        const acrostic = Canonicalizer.buildAcrostic(base);

        const compactDigits = Canonicalizer.expandNumberWords(compact).filtering("digits-only", ch => /\d/.test(ch));
        const romanDigits = Canonicalizer.expandNumberWords(Canonicalizer.expandRomanNumerals(base)).filtering("digits-only", ch => /\d/.test(ch));

        const devanagariLatin = base.mapping("devanagari-latin", ch => HinglishFold.transliterate(ch));
        const hinglishSkeleton = Canonicalizer.buildHinglishSkeleton(devanagariLatin);

        return {
            raw: visible,
            base,
            alpha,
            compact,
            alphaCompact,
            digits,
            digitsMasked,
            digitsReversed,
            separators,
            separatorsAlt,
            acrostic,
            compactDigits,
            romanDigits,
            devanagariLatin,
            hinglishSkeleton,
            allTransforms: (() => {
                const seen = new Set<string>();
                const ordered: string[] = [];
                for (const v of [visible, base, alpha, compact, alphaCompact, digits, digitsMasked, digitsReversed, separators, separatorsAlt, acrostic, compactDigits, romanDigits, devanagariLatin, hinglishSkeleton]) {
                    for (const t of v.transforms) {
                        if (!seen.has(t)) { seen.add(t); ordered.push(t); }
                    }
                }
                return ordered;
            })()
        };
    }
}
