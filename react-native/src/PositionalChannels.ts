import { CharView, Canonicalizer } from './Canonicalizer';
import { Detection, ModCategory, newId } from './ModerationTypes';
import { Extractors } from './Extractors';
import { Lexicons } from './Lexicons';

export class PositionalChannels {

    static detect(original: string, base: CharView, raw: CharView, effort: number): Detection[] {
        const out: Detection[] = [];
        const fullRange: [number, number] = [0, Math.max(1, Array.from(original).length)];

        const protocolPhrase = this.protocolHint(base.text.toLowerCase());

        if (protocolPhrase !== null) {
            out.push({
                id: newId(),
                category: ModCategory.SocialHandle,
                range: fullRange,
                surface: "",
                canonical: protocolPhrase,
                confidence: 0.72,
                transforms: [...base.transforms, "protocol-establishment"],
                effort: effort + 4,
                reason: `Describes a decoding scheme ("${protocolPhrase}") — establishing a covert channel`
            });
        }

        const channels: { name: string; payload: string; allowSpeculative: boolean }[] = [];

        const caps = this.capitalisedWordInitials(original);
        if (caps.length >= 5 && this.hasMixedCasing(original)) {
            channels.push({ name: "capitalised word initials", payload: caps, allowSpeculative: true });
        }

        const midCaps = this.midWordCapitals(original);
        if (midCaps.length >= 4) {
            channels.push({ name: "mid-word capitals", payload: midCaps, allowSpeculative: true });
        }

        const lineInit = this.lineInitials(original);
        if (lineInit.length >= 5) {
            channels.push({ name: "first letter of each line", payload: lineInit, allowSpeculative: true });
        }

        const sentInit = this.sentenceInitials(original);
        if (sentInit.length >= 5) {
            channels.push({ name: "first letter of each sentence", payload: sentInit, allowSpeculative: true });
        }

        const lineWords = this.lineFirstWords(original);
        if (lineWords.split(" ").length >= 4) {
            channels.push({ name: "first word of each line", payload: lineWords, allowSpeculative: false });
        }

        const markup = this.markupIsolatedLetters(original);
        if (markup.length >= 5) {
            channels.push({ name: "letters isolated by markup", payload: markup, allowSpeculative: true });
        }

        const lastLetters = this.wordFinalLetters(original);
        if (lastLetters.length >= 5) {
            channels.push({ name: "last letter of each word", payload: lastLetters, allowSpeculative: false });
        }

        for (const stride of [2, 3]) {
            const strided = this.stridedWordInitials(original, stride);
            if (strided.length >= 5) {
                channels.push({
                    name: `every ${stride === 2 ? "second" : "third"} word initial`,
                    payload: strided,
                    allowSpeculative: false
                });
            }
        }

        if (protocolPhrase !== null) {
            const runs = this.punctuationRunDigits(original);
            if (runs.length >= 9) {
                channels.push({ name: "repeated-punctuation run lengths", payload: runs, allowSpeculative: false });
            }
        }

        for (const channel of channels) {
            const d = this.classify(
                channel.payload,
                channel.name,
                fullRange,
                base.transforms,
                effort,
                channel.allowSpeculative
            );
            if (d) {
                out.push({ id: newId(), ...d });
                break;
            }
        }

        return out;
    }

    static wordFinalLetters(s: string): string {
        let out = "";
        for (const token of this.words(s)) {
            if (this.isAcronymOrIdentifier(token)) continue;
            const last = token[token.length - 1];
            if (!last || !/[a-zA-Z0-9]/.test(last)) continue;
            out += last;
        }
        return out;
    }

    static hasMixedCasing(s: string): boolean {
        const tokens = this.words(s).filter(t => !this.isAcronymOrIdentifier(t) && t.length >= 2);
        if (tokens.length < 6) return false;
        let upper = 0, lower = 0;
        for (const t of tokens) {
            const f = t[0];
            if (!f) continue;
            if (f === f.toUpperCase() && f !== f.toLowerCase()) upper += 1;
            else lower += 1;
        }
        return upper >= 4 && lower >= 2;
    }

    private static classify(
        payload: string,
        channelName: string,
        range: [number, number],
        transforms: string[],
        effort: number,
        anomalyPresent: boolean
    ): Omit<Detection, 'id'> | null {
        const digits = this.digitsFrom(payload);
        if (digits.length >= 10 && Extractors.isHighConfidencePhone(digits)) {
            return {
                category: ModCategory.Phone,
                range,
                surface: "",
                canonical: digits,
                confidence: 0.88,
                transforms: [...transforms, "positional-channel"],
                effort: effort + 4,
                reason: `Phone number hidden in message structure — ${channelName}`
            };
        }

        const lowered = Array.from(payload.toLowerCase()).filter(c => /[a-z]/.test(c)).join("");

        for (const name of Lexicons.platformsStrong) {
            if (name.length >= 5 && lowered.includes(name)) {
                return {
                    category: ModCategory.SocialHandle,
                    range,
                    surface: "",
                    canonical: name,
                    confidence: 0.84,
                    transforms: [...transforms, "positional-channel"],
                    effort: effort + 4,
                    reason: `Platform name hidden in message structure — ${channelName}`
                };
            }
        }

        if (anomalyPresent && lowered.length >= 5 && this.looksPronounceable(lowered)) {
            return {
                category: ModCategory.SocialHandle,
                range,
                surface: "",
                canonical: lowered,
                confidence: 0.58,
                transforms: [...transforms, "positional-channel"],
                effort: effort + 3,
                reason: `Hidden payload suspected in message structure — ${channelName} spells "${lowered}"`
            };
        }

        return null;
    }

    static capitalisedWordInitials(s: string): string {
        let out = "";
        for (const token of this.words(s)) {
            const first = token[0];
            if (!first || first !== first.toUpperCase()) continue;
            if (this.isAcronymOrIdentifier(token)) continue;
            out += first;
        }
        return out;
    }

    static midWordCapitals(s: string): string {
        let out = "";
        for (const token of this.words(s)) {
            if (this.isAcronymOrIdentifier(token)) continue;
            for (let i = 1; i < token.length; i++) {
                const ch = token[i];
                if (ch === ch.toUpperCase() && ch !== ch.toLowerCase()) out += ch;
            }
        }
        return out;
    }

    static lineInitials(s: string): string {
        let out = "";
        for (const line of s.split(/\n/)) {
            const trimmed = line.trim();
            const first = Array.from(trimmed).find(c => /[a-zA-Z]/.test(c));
            if (!first) continue;
            out += first;
        }
        return out;
    }

    static sentenceInitials(s: string): string {
        let out = "";
        for (const part of s.split(/[.!?\n]/)) {
            const trimmed = part.trim();
            const first = Array.from(trimmed).find(c => /[a-zA-Z]/.test(c));
            if (!first) continue;
            out += first;
        }
        return out;
    }

    static lineFirstWords(s: string): string {
        const parts: string[] = [];
        for (const line of s.split(/\n/)) {
            const trimmed = line.trim();
            const word = trimmed.split(/[^a-zA-Z0-9]+/).find(w => w.length > 0);
            if (!word) continue;
            parts.push(word);
        }
        return parts.join(" ");
    }

    static markupIsolatedLetters(s: string): string {
        let out = "";
        const rx = /[\*\(\[\{_~]\s*([a-zA-Z])\s*[\*\)\]\}_~]/g;
        let m: RegExpExecArray | null;
        while ((m = rx.exec(s)) !== null) {
            if (m[1]) out += m[1];
        }
        return out;
    }

    static stridedWordInitials(s: string, stride: number): string {
        const tokens = this.words(s);
        let out = "";
        let i = stride - 1;
        while (i < tokens.length) {
            const first = tokens[i][0];
            if (first && /[a-zA-Z]/.test(first)) out += first;
            i += stride;
        }
        return out;
    }

    static wordLengthDigits(s: string): string {
        let out = "";
        for (const token of this.words(s)) {
            const n = token.length;
            if (n < 1 || n > 10) return out;
            out += String(n % 10);
        }
        return out;
    }

    static punctuationRunDigits(s: string): string {
        let out = "";
        let runChar: string | null = null;
        let runLength = 0;

        const flush = () => {
            if (runLength >= 1 && runLength <= 10) {
                out += String(runLength % 10);
            }
            runLength = 0;
        };

        for (const ch of Array.from(s)) {
            if (/[a-zA-Z0-9\s]/.test(ch)) {
                if (runChar !== null) { flush(); runChar = null; }
                continue;
            }
            if (ch === runChar) {
                runLength += 1;
            } else {
                if (runChar !== null) flush();
                runChar = ch;
                runLength = 1;
            }
        }
        if (runChar !== null) flush();
        return out;
    }

    static protocolHint(loweredText: string): string | null {
        for (const phrase of Lexicons.protocolHints) {
            if (loweredText.includes(phrase)) return phrase;
        }
        return null;
    }

    static hasAnomalousCapitalisation(s: string): boolean {
        const tokens = this.words(s).filter(t => !this.isAcronymOrIdentifier(t));
        if (tokens.length < 5) return false;

        let capitalised = 0;
        let midWord = 0;
        for (const token of tokens) {
            const first = token[0];
            if (first && first === first.toUpperCase() && first !== first.toLowerCase()) capitalised += 1;
            for (let i = 1; i < token.length; i++) {
                const ch = token[i];
                if (ch === ch.toUpperCase() && ch !== ch.toLowerCase()) midWord += 1;
            }
        }

        if (midWord >= 3) return true;
        return capitalised / tokens.length >= 0.5;
    }

    private static words(s: string): string[] {
        return s.split(/[^a-zA-Z0-9]+/).filter(w => w.length > 0);
    }

    private static isAcronymOrIdentifier(token: string): boolean {
        if (/[0-9]/.test(token)) return true;
        const uppers = (token.match(/[A-Z]/g) || []).length;
        const letters = (token.match(/[a-zA-Z]/g) || []).length;
        if (letters <= 0) return true;
        if (letters <= 5 && uppers >= 2) return true;
        return uppers / letters >= 0.5 && letters > 1 && uppers > 1;
    }

    private static digitsFrom(payload: string): string {
        const view = Canonicalizer.expandNumberWords(CharView.fromString(payload.toLowerCase()));
        return view.text.replace(/[^0-9]/g, "");
    }

    static looksPronounceable(s: string): boolean {
        if (s.length === 0) return false;
        const vowels = new Set(["a", "e", "i", "o", "u"]);
        let count = 0;
        const chars = Array.from(s);
        for (let i = 0; i < chars.length; i++) {
            const ch = chars[i]!;
            if (vowels.has(ch)) count += 1;
            else if (ch === "y" && i > 0) count += 1;
        }
        if (count < 1) return false;
        const ratio = count / s.length;
        return ratio >= 0.19 && ratio <= 0.62;
    }
}
