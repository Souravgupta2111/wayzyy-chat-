import { CanonicalizerViews, Canonicalizer } from './Canonicalizer';
import { ModCategory, Detection, newId } from './ModerationTypes';
import { Lexicons } from './Lexicons';
import { bytesToUtf8 } from './Platform';
import { CharView, OffsetTable, RX } from './TextPrimitives';

export { OffsetTable, RX } from './TextPrimitives';
export type { RXMatch } from './TextPrimitives';

const BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function base64Decode(s: string): number[] {
    const clean = s.replace(/[^A-Za-z0-9+/=]/g, "").replace(/=+$/, "");
    const out: number[] = [];
    let bits = 0, acc = 0;
    for (const ch of clean) {
        const v = BASE64_ALPHABET.indexOf(ch);
        if (v === -1) continue;
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.push((acc >> bits) & 0xFF);
        }
    }
    return out;
}

export interface PhoneShape {
    e164: string;
    confidence: number;
    note: string;
}

interface PhoneCandidate {
    start: number;
    end: number;
    shape: PhoneShape;
    range: [number, number];
}

export class Extractors {
    static clockAmbiguous = new Set(["pm", "am"]);

    static isHighConfidencePhone(digits: string): boolean {
        const shape = this.validate(digits);
        if (!shape) return false;
        return shape.confidence >= 0.85;
    }

    private static validate(digits: string): PhoneShape | null {
        const d = Array.from(digits);
        if (d.length < 8 || d.length > 15) return null;

        const indianMobile = (s: string[]) => {
            if (s.length === 10 && s[0] && "6789".includes(s[0])) return true;
            return false;
        };

        if (d.length === 12 && d[0] === "9" && d[1] === "1" && indianMobile(d.slice(2))) {
            return { e164: "+" + digits, confidence: 0.95, note: "IN mobile with country code" };
        }
        if (d.length === 11 && d[0] === "0" && indianMobile(d.slice(1))) {
            return { e164: "+91" + d.slice(1).join(""), confidence: 0.90, note: "IN mobile with trunk prefix" };
        }
        if (d.length === 14 && d.slice(0, 4).join("") === "0091" && indianMobile(d.slice(4))) {
            return { e164: "+91" + d.slice(4).join(""), confidence: 0.93, note: "IN mobile, IDD prefix" };
        }
        if (indianMobile(d)) {
            return { e164: "+91" + digits, confidence: 0.92, note: "IN mobile" };
        }
        if (d.length === 11 && d[0] === "1" && d[1] && "23456789".includes(d[1])) {
            return { e164: "+" + digits, confidence: 0.74, note: "NANP with country code" };
        }
        if (d.length === 10 && d[0] && "23456789".includes(d[0])) {
            return { e164: "+1" + digits, confidence: 0.62, note: "possible NANP" };
        }
        if (d.length >= 11 && d.length <= 15) {
            return { e164: "+" + digits, confidence: 0.50, note: "generic E.164 shape" };
        }
        if (d.length === 9 || d.length === 8) {
            return { e164: digits, confidence: 0.34, note: "short / landline shape" };
        }
        return null;
    }

    static phones(digitView: CharView, suppressed: boolean, effort: number, reversed: boolean = false, spanMultiplier: number = 7): Detection[] {
        const digits = digitView.text;
        if (digits.length < 8) return [];

        const candidates: PhoneCandidate[] = [];
        const n = digits.length;
        const chars = Array.from(digits);
        const candidateCap = 400;

        outer: for (const length of [14, 12, 11, 10]) {
            if (length > n) continue;
            for (let start = 0; start <= n - length; start++) {
                if (candidates.length >= candidateCap) break outer;
                const slice = chars.slice(start, start + length).join("");
                const shape = this.validate(slice);
                if (!shape || shape.confidence < 0.50) continue;
                const orig = digitView.originalRange(start, start + length);
                if (!orig) continue;

                const allowedWidth = length * spanMultiplier + 16;
                const [lo, hi] = orig;
                if (hi - lo > allowedWidth) continue;

                candidates.push({ start, end: start + length, shape, range: orig });
            }
        }

        if (candidates.length === 0) return [];

        candidates.sort((lhs, rhs) => {
            if (lhs.shape.confidence !== rhs.shape.confidence) {
                return rhs.shape.confidence - lhs.shape.confidence;
            }
            return (rhs.end - rhs.start) - (lhs.end - lhs.start);
        });

        const taken: [number, number][] = [];
        const out: Detection[] = [];

        for (const c of candidates) {
            const overlaps = taken.some(t => Math.max(t[0], c.start) < Math.min(t[1], c.end));
            if (overlaps) continue;
            taken.push([c.start, c.end]);

            let confidence = c.shape.confidence;
            if (suppressed) confidence *= 0.55;
            if (reversed) confidence *= 0.85;

            let note = c.shape.note;
            if (reversed) note += ", written in reverse";
            if (suppressed) note += "; overlaps a legitimate numeric context";

            out.push({
                id: newId(),
                category: ModCategory.Phone,
                range: c.range,
                surface: "",
                canonical: c.shape.e164,
                confidence: Math.min(confidence, 0.99),
                transforms: digitView.transforms,
                effort: effort,
                reason: note
            });
            if (out.length >= 4) break;
        }

        return out;
    }

    private static emailRX = new RX("email", "\\b[a-z0-9._%+\\-]{1,64}@[a-z0-9.\\-]{3,64}\\.[a-z]{2,16}\\b");

    static emails(base: CharView, separators: CharView, hasMailKeyword: boolean, effort: number): Detection[] {
        const out: Detection[] = [];
        const seen = new Set<string>();

        for (const m of this.emailRX.matches(base.text)) {
            const orig = base.originalRange(m.start, m.end);
            if (!orig) continue;
            if (seen.has(m.text)) continue;
            seen.add(m.text);

            out.push({
                id: newId(),
                category: ModCategory.Email,
                range: orig,
                surface: "",
                canonical: m.text,
                confidence: 0.96,
                transforms: base.transforms,
                effort: effort,
                reason: "Literal email address"
            });
        }

        if (hasMailKeyword) {
            for (const m of this.emailRX.matches(separators.text)) {
                const orig = separators.originalRange(m.start, m.end);
                if (!orig) continue;
                if (seen.has(m.text)) continue;
                seen.add(m.text);

                out.push({
                    id: newId(),
                    category: ModCategory.Email,
                    range: orig,
                    surface: "",
                    canonical: m.text,
                    confidence: 0.88,
                    transforms: separators.transforms,
                    effort: effort + 2,
                    reason: "Email reconstructed from spelled-out separators"
                });
            }
        }
        return out;
    }

    static spelledEmails(text: string, effort: number): Detection[] {
        let s = " " + text.toLowerCase() + " ";
        const replacements: [string, string][] = [
            [" dot ", "."], [" dawt ", "."], [" point ", "."], [" period ", "."],
            [" at ", "@"], [" aht ", "@"], [" atsign ", "@"],
            [" underscore ", "_"]
        ];
        for (const [word, symbol] of replacements) {
            s = s.split(word).join(symbol);
        }
        s = s.split(" @").join("@");
        s = s.split("@ ").join("@");
        s = s.split(" .").join(".");
        s = s.split(". ").join(".");

        const out: Detection[] = [];
        const seen = new Set<string>();

        for (const m of this.emailRX.matches(s)) {
            if (seen.has(m.text)) continue;
            seen.add(m.text);

            out.push({
                id: newId(),
                category: ModCategory.Email,
                range: [0, Math.max(1, text.length)],
                surface: "",
                canonical: m.text,
                confidence: 0.90,
                transforms: ["spelled-separators"],
                effort: effort + 2,
                reason: "Email reconstructed from spelled-out separators"
            });
        }
        return out;
    }

    private static urlRX = new RX("url", "(?:https?://|www\\.)[a-z0-9\\-._~:/?#[\\]@!$&'()*+,;=%]{3,}");
    private static bareDomainRX = new RX("bare-domain", "\\b([a-z0-9][a-z0-9\\-]{0,40})\\.([a-z]{2,12})(?:/[^\\s]{0,60})?\\b");

    private static readonly ownDomains = new Set(["wayzyy.com", "wayzyy.in", "wayzyy"]);

    static classifyURL(raw: string, explicitScheme: boolean): { category: ModCategory, confidence: number, reason: string } | null {
        const lowered = raw.toLowerCase();
        let host = lowered
            .replace(/https?:\/\//g, "")
            .replace(/^www\./, "");
        host = host.split("/")[0] ?? lowered;

        if (this.ownDomains.has(host)) return null;

        let shapeConfidence: number | null = null;
        let shapeReason: string | null = null;

        if (Lexicons.shorteners.has(host)) {
            shapeConfidence = 0.94;
            shapeReason = "Known link-shortener or deep-link host";
        } else if (host.includes("xn--")) {
            shapeConfidence = 0.92;
            shapeReason = "Punycode domain — deliberately obscured host";
        } else {
            const tld = host.split(".").pop() ?? "";
            if (Lexicons.commonTLDs.has(tld)) {
                shapeConfidence = 0.68;
                shapeReason = "External link";
            } else if (explicitScheme && host.includes(".") && tld.length >= 2 && tld.length <= 24 && /^[a-zA-Z]+$/.test(tld)) {
                shapeConfidence = 0.68;
                shapeReason = "External link — scheme present, TLD outside allowlist";
            }
        }

        if (shapeConfidence === null || shapeReason === null) return null;
        return { category: ModCategory.ExternalURL, confidence: shapeConfidence, reason: shapeReason };
    }

    static spelledURLs(text: string, effort: number): Detection[] {
        let s = " " + text.toLowerCase() + " ";
        const replacements: [string, string][] = [
            [" dot ", "."], [" dawt ", "."], [" point ", "."], [" period ", "."]
        ];
        for (const [word, symbol] of replacements) {
            s = s.split(word).join(symbol);
        }
        s = s.split(" .").join(".");
        s = s.split(". ").join(".");

        const out: Detection[] = [];
        const seen = new Set<string>();

        for (const m of this.bareDomainRX.matches(s)) {
            if (seen.has(m.text)) continue;
            seen.add(m.text);

            const classified = this.classifyURL(m.text, false);
            if (!classified) continue;

            out.push({
                id: newId(),
                category: classified.category,
                range: [0, Math.max(1, text.length)],
                surface: "",
                canonical: m.text,
                confidence: 0.90,
                transforms: ["spelled-separators"],
                effort: effort + 3,
                reason: classified.reason + " (spelled-out domain)"
            });
        }
        return out;
    }

    static urls(view: CharView, contactIntent: boolean, effort: number): Detection[] {
        const out: Detection[] = [];
        const seen = new Set<string>();

        for (const m of this.urlRX.matches(view.text)) {
            const orig = view.originalRange(m.start, m.end);
            if (!orig) continue;

            const classified = this.classifyURL(m.text, true);
            if (!classified || !seen.add(m.text)) continue;

            out.push({
                id: newId(),
                category: classified.category,
                range: orig,
                surface: "",
                canonical: m.text,
                confidence: classified.confidence,
                transforms: view.transforms,
                effort: effort,
                reason: classified.reason
            });
        }

        for (const m of this.bareDomainRX.matches(view.text)) {
            const orig = view.originalRange(m.start, m.end);
            if (!orig) continue;

            const classified = this.classifyURL(m.text, false);
            if (!classified || !seen.add(m.text)) continue;

            out.push({
                id: newId(),
                category: classified.category,
                range: orig,
                surface: "",
                canonical: m.text,
                confidence: classified.confidence * 0.9,
                transforms: view.transforms,
                effort: effort,
                reason: classified.reason + " (bare domain)"
            });
        }
        return out;
    }

    private static mixedIdentRX = new RX("mixed-ident", "\\b(?=[a-z0-9]*[a-z])(?=[a-z0-9]*\\d)[a-z][a-z0-9]{3,29}\\b");
    private static dottedIdentRX = new RX("ident-dotted", "\\b[a-z][a-z0-9]{1,24}(?:[._][a-z0-9]{1,24}){1,6}\\b");

    static looksLikeBookingLocator(token: string): boolean {
        let t = token.startsWith("@") ? token.substring(1) : token;
        if (t.length < 5 || t.length > 20) return false;
        if (!/\d/.test(t) || !/[a-zA-Z]/.test(t)) return false;
        if (t.includes(".") || t.includes("_") || t.includes("@")) return false;

        let maxLetters = 0;
        let currentLetters = 0;
        for (const ch of t) {
            if (/[a-zA-Z]/.test(ch)) {
                currentLetters++;
                maxLetters = Math.max(maxLetters, currentLetters);
            } else {
                currentLetters = 0;
            }
        }

        if (maxLetters >= 5) return false;
        return Array.from(t).every(ch => /[a-zA-Z0-9\-]/.test(ch));
    }

    static bareIdentifiers(base: CharView, wordTokenCount: number, hasContactIntent: boolean, effort: number): Detection[] {
        const out: Detection[] = [];
        const seen = new Set<string>();
        const text = base.text;
        const proseAllowed = wordTokenCount <= 4 || hasContactIntent;

        const alphaPrefix = (s: string) => {
            const match = s.match(/^[a-zA-Z]+/);
            return match ? match[0] : "";
        };

        for (const rx of [this.dottedIdentRX, this.mixedIdentRX]) {
            for (const m of rx.matches(text, 6)) {
                const token = m.text;
                if (token.length < 4 || token.length > 32) continue;
                if ((token.match(/[a-zA-Z]/g) || []).length < 3) continue;
                
                const underscored = token.includes("_");
                if (!proseAllowed && !underscored) continue;
                if (this.looksLikeBookingLocator(token) && !hasContactIntent) continue;

                const parts = token.split(".");
                const tail = parts.length > 1 ? parts[parts.length - 1] : "";
                if ((Lexicons.commonTLDs && Lexicons.commonTLDs.has(tail)) || 
                    (Lexicons.upiSuffixes && Lexicons.upiSuffixes.has(tail))) continue;

                const prefix = alphaPrefix(token);
                if (Lexicons.identifierStoplist && Lexicons.identifierStoplist.has(prefix)) continue;
                if (Lexicons.numberWordsCore && (prefix in Lexicons.numberWordsCore)) continue;

                const orig = base.originalRange(m.start, m.end);
                if (!orig || seen.has(token)) continue;
                seen.add(token);

                out.push({
                    id: newId(),
                    category: ModCategory.SocialHandle,
                    range: orig,
                    surface: "",
                    canonical: token,
                    confidence: hasContactIntent ? 0.84 : 0.74,
                    transforms: base.transforms,
                    effort: effort,
                    reason: hasContactIntent ? "Identifier alongside connect intent" : "Message is primarily an identifier"
                });
            }
        }

        if (wordTokenCount <= 3 && proseAllowed) {
            const tokens = Canonicalizer.tokenize(base).filter(t => t.isWord);
            for (const token of tokens) {
                const t = token.text;
                const strong = Lexicons.platformsStrong && Lexicons.platformsStrong.has(t);
                const weak = Lexicons.platformsWeak && Lexicons.platformsWeak.has(t);
                if (!strong && !weak) continue;

                const orig = base.originalRange(token.start, token.end);
                if (!orig || seen.has("platform-only-" + t)) continue;
                seen.add("platform-only-" + t);

                out.push({
                    id: newId(),
                    category: ModCategory.SocialHandle,
                    range: orig,
                    surface: "",
                    canonical: t,
                    confidence: strong ? 0.80 : 0.72,
                    transforms: base.transforms,
                    effort: effort,
                    reason: "Platform name sent on its own"
                });
            }
        }

        return out;
    }

    private static vpaRX = new RX("vpa", "\\b([a-z0-9][a-z0-9._\\-]{2,40})@([a-z]{2,24})\\b");
    private static ifscRX = new RX("ifsc", "\\b([a-z]{4}0[a-z0-9]{6})\\b");
    private static acctRX = new RX("acct", "\\b(?:a\\/c|acc(?:ount)?|acct)\\D{0,10}(\\d{9,18})\\b");
    private static btcRX = new RX("btc", "\\b([13][a-km-zA-HJ-NP-Z1-9]{25,34})\\b", "g"); // case sensitive usually but matching swift
    private static bech32RX = new RX("bech32", "\\b(bc1[a-z0-9]{25,62})\\b");
    private static ethRX = new RX("eth", "\\b(0x[a-f0-9]{40})\\b");
    private static tronRX = new RX("tron", "\\b(T[A-Za-z0-9]{33})\\b", "g");

    static payments(base: CharView, raw: CharView, hasPaymentKeyword: boolean, effort: number): Detection[] {
        const out: Detection[] = [];

        for (const m of this.vpaRX.matches(base.text)) {
            const suffix = m.groups.length > 1 ? m.groups[1] : "";
            const known = Lexicons.upiSuffixes && Lexicons.upiSuffixes.has(suffix);
            if (!known && !(hasPaymentKeyword && (!Lexicons.commonTLDs || !Lexicons.commonTLDs.has(suffix)))) continue;
            
            const orig = base.originalRange(m.start, m.end);
            if (!orig) continue;
            out.push({
                id: newId(),
                category: ModCategory.PaymentHandle,
                range: orig,
                surface: "",
                canonical: m.text,
                confidence: known ? 0.95 : 0.74,
                transforms: base.transforms,
                effort: effort,
                reason: known ? "UPI VPA" : "Payment handle near keyword"
            });
        }

        for (const m of this.ifscRX.matches(base.text)) {
            const orig = base.originalRange(m.start, m.end);
            if (!hasPaymentKeyword || !orig) continue;
            out.push({
                id: newId(),
                category: ModCategory.BankDetails,
                range: orig,
                surface: "",
                canonical: m.text,
                confidence: 0.88,
                transforms: base.transforms,
                effort: effort,
                reason: "IFSC code"
            });
        }

        for (const m of this.acctRX.matches(base.text)) {
            const orig = base.originalRange(m.start, m.end);
            if (!orig) continue;
            out.push({
                id: newId(),
                category: ModCategory.BankDetails,
                range: orig,
                surface: "",
                canonical: m.text,
                confidence: 0.86,
                transforms: base.transforms,
                effort: effort,
                reason: "Bank account number"
            });
        }

        for (const rx of [this.btcRX, this.bech32RX, this.ethRX, this.tronRX]) {
            for (const m of rx.matches(raw.text)) {
                const orig = raw.originalRange(m.start, m.end);
                if (!orig) continue;
                out.push({
                    id: newId(),
                    category: ModCategory.CryptoAddress,
                    range: orig,
                    surface: "",
                    canonical: m.text,
                    confidence: 0.92,
                    transforms: raw.transforms,
                    effort: effort,
                    reason: `Cryptocurrency address (${rx.name})`
                });
            }
        }

        return out;
    }

    static encoded(raw: CharView, base: CharView, effort: number): Detection[] {
        const out: Detection[] = [];
        const tokens = Canonicalizer.tokenize(raw);

        const quickScan = (s: string, minPlatformLength = 3): ModCategory | null => {
            if (s.length < 6 || s.length > 400) return null;
            const lowered = s.toLowerCase();
            if (!/^[\x00-\x7F]*$/.test(lowered)) return null;

            if (this.emailRX.matches(lowered, 1).length > 0) return ModCategory.Email;

            const digits = lowered.replace(/\D/g, '');
            if (digits.length >= 10 &&
                (this.validate(digits.substring(0, 12)) || this.validate(digits.substring(0, 10)))) {
                return ModCategory.Phone;
            }
            for (const p of Lexicons.platformsStrong || []) {
                if (p.length >= minPlatformLength && lowered.includes(p)) return ModCategory.SocialHandle;
            }
            return null;
        };

        const catLabel = (c: ModCategory) => c.toLowerCase();

        const morseRX = new RX("morse", "(?:[.\\-]{1,6}[ /|]+){3,}[.\\-]{1,6}");
        for (const m of morseRX.matches(raw.text)) {
            const decoded = this.decodeMorse(m.text);
            if (decoded.length < 6) continue;
            const cat = quickScan(decoded);
            const orig = raw.originalRange(m.start, m.end);
            if (!cat || !orig) continue;
            out.push({
                id: newId(), category: cat, range: orig, surface: "",
                canonical: decoded, confidence: 0.90,
                transforms: [...raw.transforms, "morse-decode"], effort,
                reason: `Morse-encoded ${catLabel(cat)}`
            });
        }

        const binRX = new RX("binary", "(?:[01]{8}[ ,]*){4,}");
        for (const m of binRX.matches(raw.text)) {
            const decoded = this.decodeBinary(m.text);
            const cat = quickScan(decoded);
            const orig = raw.originalRange(m.start, m.end);
            if (!cat || !orig) continue;
            out.push({
                id: newId(), category: cat, range: orig, surface: "",
                canonical: decoded, confidence: 0.92,
                transforms: [...raw.transforms, "binary-decode"], effort,
                reason: `Binary-encoded ${catLabel(cat)}`
            });
        }

        for (const token of tokens) {
            if (!token.isWord || token.text.length < 8) continue;
            const t = token.text;
            const orig = raw.originalRange(token.start, token.end);
            if (!orig) continue;

            if (t.length % 2 === 0 && t.length >= 14 && /^[0-9a-fA-F]+$/.test(t)) {
                const decoded = this.decodeHex(t);
                const cat = quickScan(decoded);
                if (cat) {
                    out.push({
                        id: newId(), category: cat, range: orig, surface: "",
                        canonical: decoded, confidence: 0.90,
                        transforms: [...raw.transforms, "hex-decode"], effort,
                        reason: `Hex-encoded ${catLabel(cat)}`
                    });
                    continue;
                }
            }

            const hasUpper = /[A-Z]/.test(t);
            const hasLower = /[a-z]/.test(t);
            if (t.length >= 12 && ((hasUpper && hasLower) || /[0-9]/.test(t))) {
                const decoded = this.decodeBase64(this.padBase64(t));
                if (decoded !== null) {
                    const cat = quickScan(decoded);
                    if (cat) {
                        out.push({
                            id: newId(), category: cat, range: orig, surface: "",
                            canonical: decoded, confidence: 0.91,
                            transforms: [...raw.transforms, "base64-decode"], effort,
                            reason: `Base64-encoded ${catLabel(cat)}`
                        });
                        continue;
                    }
                }
            }
        }

        if (raw.text.includes("%")) {
            let decoded = raw.text;
            try {
                decoded = decodeURIComponent(raw.text.replace(/\+/g, " "));
            } catch { decoded = raw.text; }
            if (decoded !== raw.text) {
                const cat = quickScan(decoded);
                if (cat) {
                    const upper = Math.min((raw.offsets.length > 0 ? raw.offsets[raw.offsets.length - 1]! + 1 : 1), 400);
                    out.push({
                        id: newId(), category: cat, range: [0, Math.max(1, upper)], surface: "",
                        canonical: decoded, confidence: 0.90,
                        transforms: [...raw.transforms, "percent-decode"], effort,
                        reason: `Percent-encoded ${catLabel(cat)}`
                    });
                }
            }
        }

        if (quickScan(base.text) === null && !this.looksLikeProse(base.text)) {
            let found = false;
            for (let shift = 1; shift <= 25; shift++) {
                const candidate = this.caesar(base.text, shift);
                const cat = quickScan(candidate, 5);
                if (!cat) continue;
                const upper = Math.min((base.offsets.length > 0 ? base.offsets[base.offsets.length - 1]! + 1 : 1), 400);
                out.push({
                    id: newId(), category: cat, range: [0, Math.max(1, upper)], surface: "",
                    canonical: candidate,
                    confidence: shift === 13 ? 0.80 : 0.74,
                    transforms: [...base.transforms, "rot13-decode"], effort,
                    reason: shift === 13 ? `ROT13-encoded ${catLabel(cat)}` : `Caesar-shift(${shift}) ${catLabel(cat)}`
                });
                found = true;
                break;
            }

            if (!found) {
                const flipped = this.atbash(base.text);
                const cat = quickScan(flipped);
                if (cat) {
                    const upper = Math.min((base.offsets.length > 0 ? base.offsets[base.offsets.length - 1]! + 1 : 1), 400);
                    out.push({
                        id: newId(), category: cat, range: [0, Math.max(1, upper)], surface: "",
                        canonical: flipped, confidence: 0.74,
                        transforms: [...base.transforms, "rot13-decode"], effort,
                        reason: `Atbash-encoded ${catLabel(cat)}`
                    });
                }
            }
        }

        const natoWords = tokens.filter(t => t.isWord).filter(t => Lexicons.natoAlphabet && (t.text in Lexicons.natoAlphabet));
        if (natoWords.length >= 4) {
            const first = natoWords[0]!;
            const last = natoWords[natoWords.length - 1]!;
            const orig = base.originalRange(first.start, last.end);
            if (orig) {
                const spelled = natoWords.map(t => Lexicons.natoAlphabet[t.text]).join('');
                out.push({
                    id: newId(),
                    category: ModCategory.SocialHandle,
                    range: orig,
                    surface: "",
                    canonical: spelled,
                    confidence: 0.82,
                    transforms: [...base.transforms, "nato-letters"],
                    effort: effort + 4,
                    reason: "Identifier spelled in NATO phonetic alphabet"
                });
            }
        }

        return out;
    }

    private static readonly stopwords = new Set([
        "the", "is", "a", "an", "to", "for", "you", "and", "my", "it", "in", "on",
        "at", "of", "this", "that", "we", "be", "was", "were", "have", "has",
        "will", "if", "not", "are", "your", "our", "with", "from", "can", "but",
        "so", "do", "no", "yes", "please", "thanks", "there", "here", "all"
    ]);

    static looksLikeProse(s: string): boolean {
        const tokens = s.toLowerCase().split(/[^a-zA-Z]+/).filter(w => w.length > 0);
        let hits = 0;
        for (const t of tokens) {
            if (this.stopwords.has(t)) {
                hits += 1;
                if (hits >= 2) return true;
            }
        }
        return false;
    }

    private static padBase64(s: string): string {
        const rem = s.length % 4;
        return rem === 0 ? s : s + "=".repeat(4 - rem);
    }

    private static decodeBase64(s: string): string | null {
        try {
            const bytes = base64Decode(s);
            const decoded = bytesToUtf8(bytes);
            // Reject decodes containing replacement characters (invalid UTF-8)
            if (decoded.includes('\uFFFD')) return null;
            return decoded;
        } catch {
            return null;
        }
    }

    private static decodeHex(s: string): string {
        const chars = Array.from(s);
        const bytes: number[] = [];
        let i = 0;
        while (i + 1 < chars.length) {
            const b = parseInt(chars.slice(i, i + 2).join(''), 16);
            if (!Number.isNaN(b)) bytes.push(b);
            i += 2;
        }
        return bytesToUtf8(bytes);
    }

    private static decodeBinary(s: string): string {
        const groups = s.split(/[^01]+/).filter(g => g.length === 8);
        const bytes: number[] = [];
        for (const g of groups) bytes.push(parseInt(g, 2));
        return bytesToUtf8(bytes);
    }

    private static decodeMorse(s: string): string {
        const letters = s.split(/[ /|]+/).filter(x => x.length > 0);
        let out = "";
        for (const l of letters) {
            const ch = Lexicons.morseToChar[l];
            if (ch !== undefined) out += ch;
        }
        return out;
    }

    private static caesar(s: string, shift: number): string {
        const k = ((shift % 26) + 26) % 26;
        let out = "";
        for (const ch of s) {
            const a = ch.charCodeAt(0);
            if (a >= 97 && a <= 122) out += String.fromCharCode(((a - 97 + k) % 26) + 97);
            else if (a >= 65 && a <= 90) out += String.fromCharCode(((a - 65 + k) % 26) + 65);
            else out += ch;
        }
        return out;
    }

    private static atbash(s: string): string {
        let out = "";
        for (const ch of s) {
            const a = ch.charCodeAt(0);
            if (a >= 97 && a <= 122) out += String.fromCharCode(122 - (a - 97));
            else if (a >= 65 && a <= 90) out += String.fromCharCode(90 - (a - 65));
            else out += ch;
        }
        return out;
    }

    static originalSpanIsNumeric(range: [number, number], base: CharView): boolean {
        let sawDigit = false;
        for (let i = 0; i < base.offsets.length; i++) {
            const offset = base.offsets[i]!;
            if (offset >= range[0] && offset < range[1]) {
                const ch = base.chars[i]!;
                if (/[0-9]/.test(ch)) sawDigit = true;
                else if (/\p{L}/u.test(ch)) return false;
            }
        }
        return sawDigit;
    }

    static adjectivalPlatforms(text: string): Set<string> {
        if (!text.includes("-")) return new Set();
        const out = new Set<string>();
        const lowered = text.toLowerCase();
        for (const tail of Lexicons.compoundAdjectiveTails) {
            const rx = new RegExp(`-(${tail})(?![a-zA-Z0-9])`, "g");
            let m: RegExpExecArray | null;
            while ((m = rx.exec(lowered)) !== null) {
                let i = m.index;
                let head = "";
                while (i > 0) {
                    const prev = lowered[i - 1]!;
                    if (!/(\p{L}|\p{N}|\p{M})/u.test(prev)) break;
                    head = prev + head;
                    i--;
                }
                if (head.length >= 2) out.add(head);
            }
        }
        return out;
    }

    private static readonly connectives = new Set([
        "is", "handle", "user", "username", "name", "account", "profile", "id",
        "same", "also", "here", "there", "this", "that", "check", "follow", "add",
        "message", "text", "call", "reach", "contact", "find", "search", "please",
        "thanks", "cheers", "mine", "yours", "my", "the", "and", "you", "your",
        "will", "can", "could", "would", "just", "then", "about", "with", "from"
    ]);

    private static readonly handleShapeRX = new RX("handle-shape", "\\b[a-z][a-z0-9]{0,20}(?:[._][a-z0-9]{1,20}){1,8}\\b");
    private static readonly atHandleRX = new RX("at-handle", "@([a-z0-9](?:[a-z0-9._]){2,29})\\b");

    private static readonly mailHosts = new Set([
        "gmail", "yahoo", "hotmail", "outlook", "protonmail", "icloud", "rediff",
        "mail", "email", "proton"
    ]);

    private static readonly possessives = new Set([
        "my", "mine", "our", "ours", "mera", "meri", "mere", "hamara", "hamari"
    ]);

    private static readonly handleNouns = new Set([
        "handle", "handles", "id", "ids", "username", "user", "profile",
        "account", "page", "channel", "dm", "dms"
    ]);

    private static readonly copulas = new Set(["is", "are", "hai", "hain", "ho", "was"]);

    static handles(
        base: CharView,
        alpha: CharView,
        effort: number,
        hasContactIntent: boolean
    ): Detection[] {
        const out: Detection[] = [];
        const seen = new Set<string>();

        const baseText = base.text;
        const platformPositions: [string, number][] = [];
        for (const p of Lexicons.platformsStrong) {
            if (p.length < 4) continue;
            let idx = baseText.indexOf(p);
            while (idx !== -1) {
                platformPositions.push([p, idx + p.length]);
                idx = baseText.indexOf(p, idx + 1);
                if (platformPositions.length > 8) break;
            }
        }

        if (platformPositions.length > 0) {
            for (const m of this.handleShapeRX.matches(baseText)) {
                const parts = m.text.split(".");
                const tail = parts[parts.length - 1] ?? "";
                if (Lexicons.commonTLDs.has(tail)) continue;
                if (!(m.text.includes("_") || (m.text.match(/\./g) || []).length >= 2)) continue;

                const near = platformPositions.some(([, end]) => m.start >= end - 4 && m.start - end <= 24);
                const orig = near ? base.originalRange(m.start, m.end) : null;
                if (!orig || seen.has(m.text)) continue;
                seen.add(m.text);

                out.push({
                    id: newId(),
                    category: ModCategory.SocialHandle, range: orig, surface: "",
                    canonical: m.text, confidence: 0.87,
                    transforms: base.transforms, effort,
                    reason: "Separator-obfuscated handle near a platform keyword"
                });
            }
        }

        for (const m of this.atHandleRX.matches(base.text)) {
            const handle = m.groups[0] ?? "";
            const parts = handle.split(".");
            const tail = parts[parts.length - 1] ?? "";
            if (Lexicons.commonTLDs.has(tail)) continue;
            if (Lexicons.upiSuffixes.has(tail)) continue;
            const orig = base.originalRange(m.start, m.end);
            if (!orig || seen.has(handle)) continue;
            seen.add(handle);
            out.push({
                id: newId(),
                category: ModCategory.SocialHandle, range: orig, surface: "",
                canonical: `@${handle}`, confidence: 0.86,
                transforms: base.transforms, effort,
                reason: "Explicit social handle"
            });
        }

        const tokens = Canonicalizer.tokenize(alpha);
        const wordIdx = tokens.map((t, i) => ({ t, i })).filter(x => x.t.isWord).map(x => x.i);
        const adjectival = this.adjectivalPlatforms(base.text);

        for (let pos = 0; pos < wordIdx.length; pos++) {
            const token = tokens[wordIdx[pos]!]!.text;
            if (!(Lexicons.framedPlatforms.has(token)
                || Lexicons.platformsStrong.has(token)
                || Lexicons.platformsWeak.has(token))) continue;
            if (this.mailHosts.has(token)) continue;
            if (adjectival.has(token)) continue;

            let cursor = pos + 1;
            let sawHandleNoun = false;
            if (cursor < wordIdx.length && this.handleNouns.has(tokens[wordIdx[cursor]!]!.text)) {
                sawHandleNoun = true;
                cursor += 1;
            }
            const possessive = pos > 0 && this.possessives.has(tokens[wordIdx[pos - 1]!]!.text);
            if (!(possessive || sawHandleNoun)) continue;

            if (cursor < wordIdx.length && this.copulas.has(tokens[wordIdx[cursor]!]!.text)) {
                cursor += 1;
            }
            if (cursor >= wordIdx.length) continue;

            const cand = tokens[wordIdx[cursor]!]!;
            const t = cand.text;
            if (t.length < 4 || t.length > 30) continue;
            if (!Array.from(t).every(c => /\p{L}|\p{N}|\p{M}/u.test(c) || c === "_" || c === ".")) continue;
            if (this.connectives.has(t)) continue;
            if (this.handleNouns.has(t)) continue;
            if (Lexicons.identifierStoplist.has(t)) continue;
            if (Lexicons.compoundAdjectiveTails.has(t)) continue;
            if (Lexicons.fuzzyPlatform(t) !== null) continue;
            if (Lexicons.framedPlatforms.has(t)) continue;
            const orig = alpha.originalRange(cand.start, cand.end);
            if (!orig || seen.has(t)) continue;
            seen.add(t);
            out.push({
                id: newId(),
                category: ModCategory.SocialHandle, range: orig, surface: "",
                canonical: t, confidence: 0.86,
                transforms: alpha.transforms, effort,
                reason: `Identifier shared in an explicit "${token}" frame`
            });
        }

        for (let pos = 0; pos < wordIdx.length; pos++) {
            const token = tokens[wordIdx[pos]!]!.text;
            const isStrong = Lexicons.platformsStrong.has(token);
            const isWeak = Lexicons.platformsWeak.has(token);
            if (!(isStrong || isWeak)) continue;
            if (this.mailHosts.has(token)) continue;
            if (adjectival.has(token)) continue;

            if (Lexicons.genericWordPlatforms.has(token) && !hasContactIntent) {
                const lo3 = Math.max(0, pos - 2);
                const hi3 = Math.min(wordIdx.length - 1, pos + 2);
                let corroborated = false;
                for (let other = lo3; other <= hi3; other++) {
                    if (other === pos) continue;
                    if (Lexicons.looksLikeHandle(tokens[wordIdx[other]!]!.text)) { corroborated = true; break; }
                }
                if (!corroborated) continue;
            }

            if (this.clockAmbiguous.has(token) && pos > 0) {
                const previousToken = tokens[wordIdx[pos - 1]!]!;
                const orig = alpha.originalRange(previousToken.start, previousToken.end);
                if (orig && this.originalSpanIsNumeric(orig, base)) continue;
            }

            const lo = Math.max(0, pos - 3);
            const hi = Math.min(wordIdx.length - 1, pos + 5);
            let found = false;

            for (let other = lo; other <= hi; other++) {
                if (other === pos) continue;
                const cand = tokens[wordIdx[other]!]!;
                if (!Lexicons.looksLikeHandle(cand.text)) continue;
                const orig = alpha.originalRange(cand.start, cand.end);
                if (!orig || seen.has(cand.text)) continue;
                seen.add(cand.text);
                out.push({
                    id: newId(),
                    category: ModCategory.SocialHandle, range: orig, surface: "",
                    canonical: cand.text, confidence: isStrong ? 0.88 : 0.70,
                    transforms: alpha.transforms, effort,
                    reason: `Handle-shaped token next to "${token}"`
                });
                found = true;
                break;
            }

            if (!found) {
                const lo2 = Math.max(0, pos - 1);
                const hi2 = Math.min(wordIdx.length - 1, pos + 3);
                for (let other = lo2; other <= hi2; other++) {
                    if (other === pos) continue;
                    const cand = tokens[wordIdx[other]!]!;
                    const t = cand.text;
                    if (t.length < 5 || t.length > 30) continue;
                    if (!Array.from(t).every(c => /\p{L}|\p{N}|\p{M}/u.test(c))) continue;
                    if (this.connectives.has(t)) continue;
                    if (Lexicons.compoundAdjectiveTails.has(t)) continue;
                    if (Lexicons.fuzzyPlatform(t) !== null) continue;
                    const orig = alpha.originalRange(cand.start, cand.end);
                    if (!orig || seen.has(t)) continue;
                    seen.add(t);
                    out.push({
                        id: newId(),
                        category: ModCategory.SocialHandle, range: orig, surface: "",
                        canonical: t, confidence: isStrong ? 0.84 : 0.68,
                        transforms: alpha.transforms, effort,
                        reason: `Identifier introduced by "${token}"`
                    });
                    found = true;
                    break;
                }
            }
        }

        return out;
    }

    static platformSteering(
        base: CharView,
        alpha: CharView,
        compact: CharView,
        alphaCompact: CharView,
        hasContactIntent: boolean,
        offPlatformIntent: boolean,
        effort: number
    ): Detection[] {
        let best: { range: [number, number]; name: string; how: string } | null = null;

        const compactMatchIsCredible = (orig: [number, number], matchLength: number, reference: CharView): boolean => {
            if (orig[1] - orig[0] > matchLength) return true;
            const originalCharacter = (index: number): string | null => {
                if (index < 0) return null;
                const k = reference.offsets.indexOf(index);
                if (k === -1) return null;
                return reference.chars[k] ?? null;
            };
            const before = originalCharacter(orig[0] - 1);
            if (before && /(\p{L}|\p{N}|\p{M})/u.test(before)) return false;
            const after = originalCharacter(orig[1]);
            if (after && /(\p{L}|\p{N}|\p{M})/u.test(after)) return false;
            return true;
        };

        for (const token of Canonicalizer.tokenize(alpha)) {
            if (!token.isWord) continue;
            const t = token.text;
            const stripped = Lexicons.platformsStripped.has(t);
            const fuzzy = Lexicons.fuzzyPlatform(t);
            if (!stripped && fuzzy === null) continue;
            if (Lexicons.genericWordPlatforms.has(t) && !hasContactIntent && !offPlatformIntent) continue;
            const orig = alpha.originalRange(token.start, token.end);
            if (orig) {
                let how: string;
                if (stripped) how = "vowel-stripped spelling";
                else if (fuzzy !== null && fuzzy !== t) how = `platform name misspelled as "${t}"`;
                else how = "platform name";
                best = { range: orig, name: fuzzy ?? t, how };
                break;
            }
        }

        if (best === null) {
            for (const view of [compact, alphaCompact]) {
                const text = view.text;
                if (text.length < 4) continue;
                for (const name of Lexicons.platformsStrong) {
                    if (name.length < 5) continue;
                    const idx = text.indexOf(name);
                    if (idx === -1) continue;
                    const orig = view.originalRange(idx, idx + name.length);
                    if (orig && compactMatchIsCredible(orig, name.length, alpha)) {
                        best = { range: orig, name, how: "platform name with separators removed" };
                        break;
                    }
                }
                if (best !== null) break;
            }
        }

        if (best === null) {
            const uncollapsed = alphaCompact.text;
            const collapsed = Lexicons.collapseRuns(uncollapsed);
            for (const name of Lexicons.platformsCollapsed) {
                if (name.length < 5) continue;
                if (!collapsed.includes(name) || uncollapsed.includes(name)) continue;
                const upper = Math.min(alphaCompact.offsets.length > 0 ? alphaCompact.offsets[alphaCompact.offsets.length - 1]! + 1 : 1, 400);
                best = { range: [0, Math.max(1, upper)], name, how: "platform name with repeated letters" };
                break;
            }
        }

        if (best !== null && this.adjectivalPlatforms(base.text).has(best.name)) {
            best = null;
        }

        if (best === null) return [];

        const confidence = hasContactIntent || offPlatformIntent ? 0.88 : 0.72;
        return [{
            id: newId(),
            category: ModCategory.SocialHandle,
            range: best.range,
            surface: "",
            canonical: best.name,
            confidence,
            transforms: base.transforms,
            effort,
            reason: `Steering to an off-platform channel — ${best.how}`
        }];
    }

    static leetDigitRuns(base: CharView, compact: CharView, effort: number): Detection[] {
        const out: Detection[] = [];
        const seen = new Set<string>();

        const scan = (view: CharView) => {
            const chars = view.chars;
            let i = 0;

            while (i < chars.length) {
                let j = i;
                let digits = "";
                let letterCount = 0;
                while (j < chars.length) {
                    const ch = chars[j]!;
                    if (/[0-9]/.test(ch)) {
                        digits += ch;
                    } else {
                        const mapped = Lexicons.letterToDigit[ch] ?? Lexicons.letterToDigit[ch.toLowerCase()];
                        if (mapped !== undefined) {
                            digits += mapped;
                            letterCount += 1;
                        } else break;
                    }
                    j += 1;
                }

                let transitions = 0;
                if (j > i) {
                    for (let k = i + 1; k < j; k++) {
                        if (/[0-9]/.test(chars[k]!) !== /[0-9]/.test(chars[k - 1]!)) transitions += 1;
                    }
                }

                if (digits.length >= 10 && letterCount >= 2 && transitions >= 4) {
                    const d = Array.from(digits);
                    let matched = false;
                    for (const length of [12, 11, 10]) {
                        if (length > d.length) continue;
                        for (let start = 0; start <= d.length - length; start++) {
                            const candidate = d.slice(start, start + length).join('');
                            if (!this.isHighConfidencePhone(candidate)) continue;
                            const orig = view.originalRange(i + start, i + start + length);
                            if (!orig || seen.has(candidate)) continue;
                            seen.add(candidate);
                            out.push({
                                id: newId(),
                                category: ModCategory.Phone, range: orig, surface: "",
                                canonical: `+91${candidate}`, confidence: 0.90,
                                transforms: [...view.transforms, "reverse-leet"], effort,
                                reason: "Phone number written with digits substituted as letters"
                            });
                            matched = true;
                            break;
                        }
                        if (matched) break;
                    }
                }

                i = Math.max(j, i + 1);
            }
        };

        scan(base);
        scan(compact);
        return out;
    }
}
