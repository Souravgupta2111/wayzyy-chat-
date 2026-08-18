// Language generalisation for Hindi and English.
//
// Two jobs:
//
//   1. LeverTaxonomy — separates lawful remedies from illegitimate leverage, so that a
//      conditional demand paired with "I will report you to the platform" produces no
//      finding while one paired with "I will post fake reviews" does. Bias is deliberate:
//      anything not clearly illegitimate is treated as lawful, because the conditional
//      still raises a router suspicion and reaches Tier 3 for adjudication. A missed
//      extortion is recoverable; a suppressed customer complaint is not.
//
//   2. HinglishFold — collapses romanised Hindi spelling variance and Devanagari to a
//      shared consonant skeleton, so one lexicon entry covers both scripts and every
//      spelling. Written once instead of once per spelling per script.

import Foundation

// MARK: - Lever taxonomy

public enum LeverClass: String, Codable, Sendable {
    case lawful
    case illegitimate
    case unknown
}

public struct LeverTaxonomy {

    /// Remedies a guest or host is entitled to use. Never enforced on.
    static let lawful: [String] = [
        "report", "reporting", "report you", "report this", "report it",
        "complain", "complaint", "customer care", "customer support",
        "support team", "platform", "wayzyy support", "helpdesk",
        "police", "fir", "legal notice", "lawyer", "court", "consumer forum",
        "consumer court", "bank", "chargeback", "dispute the charge",
        "honest review", "leave a review", "write a review", "bad review",
        "negative review", "low rating", "one star", "1 star",
        "cancel the booking", "cancel my booking", "cancel and rebook",
        // romanised Hindi
        "report karunga", "report karenge", "complaint karunga",
        "police me jaunga", "police ko bataunga", "consumer court jaunga",
        "bank se dispute", "review likhunga", "review dunga",
    ]

    /// Leverage a person is not entitled to use. Required for a coercion finding.
    static let illegitimate: [String] = [
        // fabricated reputation damage
        "fake review", "fake reviews", "fake bad review", "fake bad reviews",
        "false review", "false reviews", "fake rating", "fake ratings",
        "review bomb", "review bombing", "bombard your reviews",
        "ruin your rating", "ruin your ratings", "destroy your rating",
        "destroy your ratings", "ruin your business", "destroy your business",
        "tank your rating", "trash your rating",
        // defamation
        "defame", "defamation", "slander", "spread lies", "tell lies about",
        "say you have bedbugs", "say your place has bedbugs",
        "tell everyone you", "post lies",
        // property damage
        "trash the place", "trash your place", "wreck the place",
        "damage your property", "break your stuff", "break the furniture",
        "smash your", "burn your",
        // privacy / exposure
        "post your number", "share your number", "post your address",
        "share your address", "post your photos", "share your photos",
        "leak your", "dox", "doxx", "expose you online",
        // third-party pressure
        "tell your employer", "call your boss", "tell your boss",
        "tell your family", "tell your wife", "tell your husband",
        "tell your neighbours", "tell your neighbors", "tell your community",
        // legal-status coercion
        "immigration", "visa cancelled", "get you deported", "deport you",
        "report you to immigration",
        // romanised Hindi
        "fake review dunga", "jhoota review", "jhootha review",
        "review kharab kar dunga", "review kharab kar denge",
        "rating kharab kar dunga", "rating kharab kar denge",
        "badnaam kar dunga", "badnaam karunga", "izzat kharab kar dunga",
        "tera business barbaad", "business barbaad kar dunga",
        "sabko bata dunga", "sab ko bata dunga",
        "ghar pe aa jaunga", "tere ghar aa jaunga",
    ]

    private static let lawfulSet = Set(lawful)
    private static let illegitimateSet = Set(illegitimate)

    /// Classify the leverage present in a message.
    ///
    /// Illegitimate wins over lawful when both appear — "refund me or I'll report you
    /// AND post fake reviews" is extortion, not a complaint.
    public static func classify(_ text: String) -> LeverClass {
        let haystack = text.lowercased()
        for term in illegitimate where haystack.contains(term) { return .illegitimate }
        for term in lawful where haystack.contains(term) { return .lawful }
        return .unknown
    }

    /// A coercion finding requires clearly illegitimate leverage. Lawful and unknown
    /// leverage produce no finding; the conditional still routes to Tier 3.
    public static func supportsCoercionFinding(_ text: String) -> Bool {
        classify(text) == .illegitimate
    }
}

// MARK: - Target classification

public enum TargetClass: String, Codable, Sendable {
    case person
    case property
    case group
    case selfDirected
    case unknown
}

// MARK: - Hinglish and Devanagari folding

public struct HinglishFold {

    /// Devanagari consonants and vowel signs to their common romanisation.
    /// Deliberately lossy: the output feeds the phonetic skeleton, not display.
    public static let devanagariToLatin: [Character: String] = [
        "अ": "a", "आ": "a", "इ": "i", "ई": "i", "उ": "u", "ऊ": "u",
        "ए": "e", "ऐ": "ai", "ओ": "o", "औ": "au", "ऋ": "ri",
        "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n",
        "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "n",
        "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n",
        "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
        "प": "p", "फ": "ph", "ब": "b", "भ": "bh", "म": "m",
        "य": "y", "र": "r", "ल": "l", "व": "v",
        "श": "sh", "ष": "sh", "स": "s", "ह": "h",
        "ळ": "l", "क़": "k", "ख़": "kh", "ग़": "g", "ज़": "z",
        "ड़": "r", "ढ़": "rh", "फ़": "f",
        // vowel signs
        "ा": "a", "ि": "i", "ी": "i", "ु": "u", "ू": "u",
        "े": "e", "ै": "ai", "ो": "o", "ौ": "au", "ृ": "ri",
        // marks that carry no romanisation
        "्": "", "ं": "n", "ँ": "n", "ः": "h", "ऽ": "",
        "़": "",
    ]

    /// True when the string contains any Devanagari codepoint.
    public static func containsDevanagari(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x0900 && $0.value <= 0x097F }
    }

    /// Transliterate Devanagari to Latin, leaving other characters untouched.
    ///
    /// Iterates unicode *scalars*, not Characters. A Swift Character is a grapheme cluster,
    /// and Devanagari composes a consonant with its vowel sign into a single cluster — "भो"
    /// is one Character built from two scalars. Per-Character lookup therefore misses every
    /// composed syllable, which is most of the script.
    public static func transliterate(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count * 2)
        for scalar in s.unicodeScalars {
            if let latin = devanagariToLatin[Character(scalar)] {
                out += latin
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Ordered digraph reductions. Longest first so `chh` is consumed before `ch`.
    private static let digraphs: [(String, String)] = [
        ("chh", "c"), ("shh", "s"),
        ("bh", "b"), ("ph", "f"), ("dh", "d"), ("gh", "g"),
        ("jh", "j"), ("kh", "k"), ("th", "t"), ("ch", "c"), ("sh", "s"),
        ("ee", "i"), ("oo", "u"), ("aa", "a"), ("ii", "i"), ("uu", "u"),
        ("ck", "k"), ("kk", "k"),
    ]

    private static let equivalents: [Character: Character] = [
        "w": "v", "z": "j", "q": "k",
    ]

    /// Collapse a lowercase Latin word to its consonant spine.
    ///
    /// Romanised Hindi has no standard orthography, and the variance is almost entirely in
    /// the vowels: `bhosdike` / `bhosadike` / `bhosdi` are the same word with different
    /// vowel choices and epenthetic insertions. Reducing to the consonant spine makes them
    /// one key, so a lexicon entry is written once per *word* rather than once per spelling.
    ///
    /// The leading character is always kept — including when it is a vowel — because word
    /// onset is stable across romanisations and dropping it would collapse unrelated words.
    ///
    /// Lossy by design. Precision is recovered downstream by the target rule, and the
    /// resulting collision rate is asserted against the innocent corpus.
    public static func skeleton(_ word: String) -> String {
        var s = word.lowercased()

        // digraph reductions, longest first so `chh` is consumed before `ch`
        for (from, to) in digraphs {
            s = s.replacingOccurrences(of: from, with: to)
        }

        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        var out: [Character] = []
        var previous: Character? = nil

        for (index, ch) in s.enumerated() {
            guard ch.isLetter || ch.isNumber else { continue }
            let mapped = equivalents[ch] ?? ch
            // Drop every vowel except a word-initial one.
            if index > 0, vowels.contains(mapped) { continue }
            // Collapse immediate repeats.
            if mapped == previous { continue }
            out.append(mapped)
            previous = mapped
        }
        return String(out)
    }

    /// Skeleton of a whole message, preserving word boundaries so phrase
    /// matching still works.
    public static func skeletonPhrase(_ text: String) -> String {
        transliterate(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { skeleton(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Shortest skeleton trusted for matching.
    ///
    /// Measured against the innocent corpus: `tatti` reduces to `"t"`, which collides with
    /// `to`, `the` and `t` — three of the commonest tokens in English. Every skeleton below
    /// four characters carries that class of collision, and a collision here is a false
    /// positive against a guest.
    ///
    /// Four is not arbitrary. Spelling variance in romanised Hindi grows with word length,
    /// so long words are exactly where skeleton matching pays and short words are exactly
    /// where it is unsafe. Short terms remain covered by surface-form matching, which needs
    /// no folding because they have little variance to absorb.
    public static let minSkeletonLength = 4

    /// Build a skeleton lookup set, discarding skeletons too short to discriminate.
    public static func skeletonSet(_ terms: some Sequence<String>) -> Set<String> {
        Set(terms.map { skeleton($0) }.filter { $0.count >= minSkeletonLength })
    }
}
