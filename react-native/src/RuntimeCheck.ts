// One-time runtime sanity checks for the target JS engine (Hermes on React
// Native). The engine's tokenizer and number-word expander depend on Unicode
// property escapes (\p{L}, \p{N}, \p{M}); older Hermes builds silently
// mis-handle them, which would break Devanagari/Hinglish detection without any
// error being thrown. Run once at app startup.

export interface RuntimeCheckResult {
    ok: boolean;
    failures: string[];
}

export function checkRuntimeCompatibility(): RuntimeCheckResult {
    const failures: string[] = [];

    // 1. Unicode property escapes must be supported at all.
    try {
        if (!/\p{L}/u.test("a")) {
            failures.push("unicode property escapes not supported (\\p{L})");
        }
    } catch {
        failures.push("unicode property escapes throw at parse/construct time");
        return { ok: false, failures };
    }

    // 2. Devanagari word with a combining matra must tokenize as ONE word.
    //    "नौ" is न + ौ (matra, category Mn). If matras are excluded, this
    //    splits into two tokens and Hindi number-word detection dies.
    {
        let count = 0;
        const rx = /[\p{L}\p{N}\p{M}]+/gu;
        const matches = "नौ आठ".match(rx) ?? [];
        count = matches.length;
        if (count !== 2) {
            failures.push(`devanagari tokenization broken: expected 2 words, got ${count}`);
        }
        if (!/[\p{L}]/u.test("न") || !/[\p{M}]/u.test("ौ")) {
            failures.push("Devanagari base/matra classes not matched by \\p{L}/\\p{M}");
        }
    }

    // 3. Thai digits must fold through the Nd class.
    if (!/\p{Nd}/u.test("๙")) {
        failures.push("\\p{Nd} does not cover Thai digits");
    }

    // 4. String.fromCodePoint / codePointAt (used by the canonicalizer).
    if (String.fromCodePoint(0x1F1E6) !== "🇦" || "नौ".codePointAt(0) !== 0x928) {
        failures.push("codePoint handling broken");
    }

    // 5. TextEncoder availability is optional (Platform has a fallback), but
    //    flag it so the caller knows the fast path is missing.
    if (typeof TextEncoder === 'undefined') {
        failures.push("TextEncoder missing — Platform fallback will be used (slower)");
    }

    return { ok: failures.length === 0, failures };
}
