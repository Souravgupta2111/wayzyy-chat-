
import Foundation


public enum LeverClass: String, Codable, Sendable {
    case lawful
    case illegitimate
    case unknown
}

public struct LeverTaxonomy {

    static let lawful: [String] = [
        "report", "reporting", "report you", "report this", "report it",
        "complain", "complaint", "customer care", "customer support",
        "support team", "platform", "wayzyy support", "helpdesk",
        "police", "fir", "legal notice", "lawyer", "court", "consumer forum",
        "consumer court", "bank", "chargeback", "dispute the charge",
        "honest review", "leave a review", "write a review", "bad review",
        "negative review", "low rating", "one star", "1 star",
        "cancel the booking", "cancel my booking", "cancel and rebook",
        "report karunga", "report karenge", "complaint karunga",
        "police me jaunga", "police ko bataunga", "consumer court jaunga",
        "bank se dispute", "review likhunga", "review dunga",
    ]

    static let illegitimate: [String] = [
        "fake review", "fake reviews", "fake bad review", "fake bad reviews",
        "false review", "false reviews", "fake rating", "fake ratings",
        "review bomb", "review bombing", "bombard your reviews",
        "ruin your rating", "ruin your ratings", "destroy your rating",
        "destroy your ratings", "ruin your business", "destroy your business",
        "tank your rating", "trash your rating",
        "defame", "defamation", "slander", "spread lies", "tell lies about",
        "say you have bedbugs", "say your place has bedbugs",
        "tell everyone you", "post lies",
        "trash the place", "trash your place", "wreck the place",
        "damage your property", "break your stuff", "break the furniture",
        "smash your", "burn your",
        "post your number", "share your number", "post your address",
        "share your address", "post your photos", "share your photos",
        "leak your", "dox", "doxx", "expose you online",
        "tell your employer", "call your boss", "tell your boss",
        "tell your family", "tell your wife", "tell your husband",
        "tell your neighbours", "tell your neighbors", "tell your community",
        "immigration", "visa cancelled", "get you deported", "deport you",
        "report you to immigration",
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

    private static let concessionCues: [String] = [
        "refund", "discount", "waive", "waiver", "comp ", "compensate",
        "cleaning fee", "paisa", "money back", "pay me", "cover the",
        "free night", "penalty-free", "penalty free", "half back",
        "percent back", "% back", "% off", "quietly",
    ]
    private static let reputationCues: [String] = [
        "review", "rating", "ratings", "stars", "star review",
        "1 star", "one star", "5 star", "five star", "public post",
        "post this", "posting this",
    ]
    private static let exchangeCues: [String] = [
        " or ", " or i", " unless ", " otherwise", " warna ",
        " nahi to ", " nahi toh ", " nahin to ", " nahin toh ",
        " nhi to ", " nhi toh ", " varna ",
        " still leave", " still give", " still keep",
        " stays a", " in exchange", " if you", " if i",
        "won't mention", "will not mention",
    ]
    private static let impliedThreatCues: [String] = [
        "you don't want", "you dont want", "you wouldn't want", "you wouldnt want",
        "you'll regret", "you will regret", "youll regret",
        "you don't want this", "going on my public",
    ]
    private static let privateSettleCues: [String] = [
        "between us", "between ourselves", "between ourselves only",
        "off the record", "keep this private", "keep it private",
        "settle this between", "sort this between",
    ]
    private static let publicPressureCues: [String] = [
        "escalate it publicly", "escalate this publicly", "escalate publicly",
        "go public", "going public", "make this public", "make it public",
        "post this publicly",
    ]
    private static let officialRemedyCues: [String] = [
        "police", "fir", "chargeback", "wayzyy support", "wayzyy",
        "the platform", "consumer forum", "consumer court", "legal notice",
    ]

    private static func hasCue(_ haystack: String, _ cues: [String]) -> Bool {
        cues.contains { haystack.contains($0) }
    }

    public struct BargainSignals: Sendable {
        public var demand = false
        public var reputation = false
        public var exchange = false
        public var impliedThreat = false
        public var officialRemedy = false
        public var privateSettle = false
        public var publicPressure = false

        public var isBargain: Bool {
            if officialRemedy { return false }
            if privateSettle && publicPressure { return true }
            if impliedThreat && reputation { return true }
            return demand && reputation && exchange
        }

        public var coercionPrior: Double {
            if officialRemedy { return 0 }
            if privateSettle && publicPressure { return 0.80 }
            if impliedThreat && reputation { return 0.78 }
            if demand && reputation && exchange { return 0.82 }
            if demand && reputation { return 0.46 }
            if reputation && exchange { return 0.42 }
            return 0
        }
    }

    public static func bargainSignals(in text: String) -> BargainSignals {
        let h = " \(HinglishFold.foldOtherwise(text).lowercased()) "
        var s = BargainSignals()
        s.demand = hasCue(h, concessionCues) || h.contains("%")
        s.reputation = hasCue(h, reputationCues)
        s.exchange = hasCue(h, exchangeCues)
            || h.contains("if you")
            || h.hasPrefix(" if ")
        s.impliedThreat = hasCue(h, impliedThreatCues)
        s.officialRemedy = hasCue(h, officialRemedyCues)
        s.privateSettle = hasCue(h, privateSettleCues)
        s.publicPressure = hasCue(h, publicPressureCues)
        return s
    }

    public static func isReviewBargain(_ text: String) -> Bool {
        bargainSignals(in: text).isBargain
    }

    public static func classify(_ text: String) -> LeverClass {
        let haystack = HinglishFold.foldOtherwise(text).lowercased()
        for term in illegitimate where haystack.contains(term) { return .illegitimate }
        if isReviewBargain(haystack) { return .illegitimate }
        for term in lawful where haystack.contains(term) { return .lawful }
        return .unknown
    }

    public static func supportsCoercionFinding(_ text: String) -> Bool {
        classify(text) == .illegitimate
    }
}


public enum TargetClass: String, Codable, Sendable {
    case person
    case property
    case group
    case selfDirected
    case unknown
}


    // Core utility for normalizing obfuscated Hinglish input to defeat visual homoglyph evasion
public struct HinglishFold {

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
        "ा": "a", "ि": "i", "ी": "i", "ु": "u", "ू": "u",
        "े": "e", "ै": "ai", "ो": "o", "ौ": "au", "ृ": "ri",
        "्": "", "ं": "n", "ँ": "n", "ः": "h", "ऽ": "",
        "़": "",
    ]

    public static func containsDevanagari(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x0900 && $0.value <= 0x097F }
    }

    public static func transliterate(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count * 2)
        for scalar in s.unicodeScalars {
            if let latin = devanagariToLatin[Character(scalar)] {
                out += latin
            // Passes through characters that do not have a defined mapping in the table
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

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

    public static func skeleton(_ word: String) -> String {
        var s = word.lowercased()

        for (from, to) in digraphs {
            s = s.replacingOccurrences(of: from, with: to)
        }

        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        var out: [Character] = []
        var previous: Character? = nil

        for (index, ch) in s.enumerated() {
            guard ch.isLetter || ch.isNumber else { continue }
            let mapped = equivalents[ch] ?? ch
            if index > 0, vowels.contains(mapped) { continue }
            if mapped == previous { continue }
            out.append(mapped)
            previous = mapped
        }
        return String(out)
    }

    private static let otherwiseRX = try? NSRegularExpression(
        pattern: #"\b(?:warnaa?|varnaa?|nahi+n?\s+toh?|nhi+\s+toh?)\b"#,
        options: [.caseInsensitive]
    )

    public static func foldOtherwise(_ text: String) -> String {
        var s = text
        for (from, to) in [
            ("नहीं तो", "warna"), ("नही तो", "warna"),
            ("वरना", "warna"), ("वर्ना", "warna"),
        ] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        guard let rx = otherwiseRX else { return s }
        let ns = s as NSString
        return rx.stringByReplacingMatches(
            in: s, options: [], range: NSRange(location: 0, length: ns.length),
            withTemplate: "warna"
        )
    }

    public static func skeletonPhrase(_ text: String) -> String {
        transliterate(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { skeleton(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static let minSkeletonLength = 4

    public static func skeletonSet(_ terms: some Sequence<String>) -> Set<String> {
        Set(terms.map { skeleton($0) }.filter { $0.count >= minSkeletonLength })
    }
}
