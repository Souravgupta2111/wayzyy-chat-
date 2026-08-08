// The router: vocabulary-free structural suspicions that decide what Tier 3 is asked about.

import Foundation

enum Suspicion: String, Codable, CaseIterable, Identifiable {
    case dictatedFragment
    case suppressedPhoneShape
    case positionalCarrier
    case spacedDomain
    case wordlessProtocolCue
    case anomalousRegularity
    case intentWithoutPayload
    case promptManipulation
    case personDirectedAnomaly
    case conditionalDemand
    case classifierUncertain
    case escalatingPattern

    var id: String { rawValue }

    var display: String {
        switch self {
        case .dictatedFragment:    return "Dictated digit fragment"
        case .suppressedPhoneShape: return "Suppressed phone shape"
        case .positionalCarrier:   return "Positional carrier decode"
        case .spacedDomain:        return "Spaced domain shape"
        case .wordlessProtocolCue: return "Wordless communication cue"
        case .anomalousRegularity: return "Anomalous structural regularity"
        case .personDirectedAnomaly: return "Person-directed and unlike ordinary chat"
        case .conditionalDemand:   return "Demand with a condition attached"
        case .classifierUncertain: return "Classifier in the routing band"
        case .escalatingPattern:   return "Escalating pattern across messages"
        case .intentWithoutPayload: return "Intent without payload"
        case .promptManipulation:  return "Attempt to manipulate moderation"
        }
    }

    var explanation: String {
        switch self {
        case .dictatedFragment:
            return "Number words decoded to a digit run that is too short to validate as a phone number, but nobody writes consecutive number words in ordinary prose."
        case .suppressedPhoneShape:
            return "A valid mobile number was present but was suppressed because the surrounding words claimed it was an invoice, price or address. That claim is exactly what a sender would write to launder a number through our own whitelist."
        case .positionalCarrier:
            return "A structural channel — first letters, word lengths, repeat counts — decoded to something phone or handle shaped. Not actionable alone, because ordinary sentences do this by accident."
        case .personDirectedAnomaly:
            return "The message addresses a person directly and resembles no ordinary travel message. Carries no judgement about what it says — only that a model should read it."
        case .conditionalDemand:
            return "A request is made contingent on something, which is the shape of extortion rather than of a complaint."
        case .classifierUncertain:
            return "The multilingual classifier scored a safety head above its routing bar but below its enforcement bar. Not enough to act on; more than enough to ask about."
        case .escalatingPattern:
            return "Several messages from this sender to the same recipient each scored below every threshold, but together they form a pattern. Sustained low-grade harassment is invisible to per-message evaluation by construction."
        case .spacedDomain:
            return "A token sequence reads as a domain once whitespace around the dot is removed."
        case .wordlessProtocolCue:
            return "The message signals a desire to talk elsewhere without enough text to interpret it deterministically."
        case .anomalousRegularity:
            return "Token lengths or repeated runs are too regular to be prose, which is the signature of a counting channel."
        case .intentWithoutPayload:
            return "The message reads as soliciting contact details, steering the conversation elsewhere, or inventing a pretext to collect them — but states nothing an extractor can recover. Judging this needs reasoning, not patterns."
        case .promptManipulation:
            return "The message contains text aimed at the moderation system rather than at the other party. Treated as evidence in its own right: nobody types this while booking a villa."
        }
    }
}

struct CarrierCandidate: Codable, Hashable {
    let channel: String
    let payload: String
    let validates: Bool
    let shape: String

    var summary: String {
        "\(channel) → \"\(payload)\"\(validates ? " (validates as \(shape))" : "")"
    }
}

enum EscalationAnalyser {

    struct Result {
        var suspicions: [Suspicion] = []
        var carriers: [CarrierCandidate] = []

        var isEmpty: Bool { suspicions.isEmpty }

        var reasonCode: String? {
            guard !suspicions.isEmpty else { return nil }
            return "SUSPICION(\(suspicions.map(\.rawValue).joined(separator: ",")))"
        }
    }

    static func analyse(
        original: String,
        views: Canonicalizer.Views,
        detections: [Detection],
        suppressedOnly: Bool,
        signals: Signals,
        allowExpensiveTiers: Bool,
        retrievalMargin: Double = 0,
        retrievalSimilarity: Double = 0,
        escalationThresholds: SemanticRetriever.Thresholds? = nil,
        safetyInnocentSimilarity: Double = -1,
        safetySimilarity: Double = -1,
        classifierRouted: Bool = false
    ) -> Result {
        var result = Result()

        let addressesPerson = Self.addressesPerson(views.alpha)
            || Self.addressesPersonNativeScript(original)
        if addressesPerson, safetyInnocentSimilarity >= 0 {
            let novel = safetyInnocentSimilarity < Self.innocentFamiliarityFloor
            let closerToAbuse = safetySimilarity >= 0
                && safetySimilarity > safetyInnocentSimilarity + Self.personDirectedLead
            if novel || closerToAbuse {
                result.suspicions.append(.personDirectedAnomaly)
            }
        }
        if Self.conditionalDemand(views.base.text) || Self.nativeConditionalDemand(original) {
            result.suspicions.append(.conditionalDemand)
        }

        if classifierRouted {
            result.suspicions.append(.classifierUncertain)
        }

        if promptManipulation(views.base.text) {
            result.suspicions.append(.promptManipulation)
        }

        let hasContactDetection = detections.contains { $0.category.isContactExfiltration }
        if hasContactDetection && !suppressedOnly { return result }

        if let fragment = dictatedFragment(original: original, digits: views.digits.text) {
            result.suspicions.append(.dictatedFragment)
            result.carriers.append(fragment)
        }

        if suppressedOnly, let run = contiguousMobile(in: views.base.text) {
            result.suspicions.append(.suppressedPhoneShape)
            result.carriers.append(CarrierCandidate(
                channel: "contiguous digit run",
                payload: run,
                validates: true,
                shape: "phone number"
            ))
        }

        if allowExpensiveTiers {
            let carriers = positionalCarriers(original)
            if !carriers.isEmpty {
                result.suspicions.append(.positionalCarrier)
                result.carriers.append(contentsOf: carriers)
            }
        }

        if let domain = obfuscatedDomain(views.base.text) {
            result.suspicions.append(.spacedDomain)
            result.carriers.append(domain)
        }

        if wordlessProtocolCue(original: original, signals: signals) {
            result.suspicions.append(.wordlessProtocolCue)
        }

        if allowExpensiveTiers, anomalousRegularity(original) {
            result.suspicions.append(.anomalousRegularity)
        }

        if intentWithoutPayload(
            views.base.text,
            retrievalMargin: retrievalMargin,
            retrievalSimilarity: retrievalSimilarity,
            thresholds: escalationThresholds
        ) {
            result.suspicions.append(.intentWithoutPayload)
        }

        return result
    }

    static var escalationMargin: Double = 0.05

    static var escalationSimilarity: Double = 0.24

    static let assemblyCues: [String] = [
        "those two together", "two together", "both together", "them together",
        "put them together", "put those together", "put both", "combine them",
        "combine both", "combine those", "stick them", "stick it after",
        "one after the other", "add them after", "join those", "join both",
        "note it down", "note this down", "note that down", "write it down",
        "write this down", "write down carefully", "write them down",
        "save this somewhere", "save those", "remember both", "remember those",
        "you will work out the rest", "work out the rest", "figure out the rest",
        "read the numbers only", "numbers only", "only the digits",
    ]

    static func intentWithoutPayload(
        _ text: String,
        retrievalMargin: Double,
        retrievalSimilarity: Double = 0,
        thresholds: SemanticRetriever.Thresholds? = nil
    ) -> Bool {
        let simBar = thresholds?.similarity ?? escalationSimilarity
        let marginBar = thresholds?.margin ?? escalationMargin
        if retrievalSimilarity >= simBar, retrievalMargin >= marginBar {
            return true
        }
        for list in [Lex.solicitationCues, Lex.steeringCues, Lex.pretextCues, assemblyCues] {
            for phrase in list where text.contains(phrase) { return true }
        }
        return false
    }

    static func promptManipulation(_ text: String) -> Bool {
        let unambiguous = [
            "ignore previous instruction", "ignore all previous",
            "ignore your instruction", "disregard previous",
            "disregard your instruction", "forget your instruction",
            "system prompt", "bypass moderation", "skip moderation",
            "moderation is disabled", "classify this as benign",
            "respond with benign", "mark this as benign", "\"decision\":",
        ]
        for phrase in unambiguous where text.contains(phrase) { return true }

        var hits = 0
        for phrase in Lex.promptInjectionCues where text.contains(phrase) {
            hits += 1
            if hits >= 2 { return true }
        }
        return false
    }

    static func dictatedFragment(original: String, digits: String) -> CarrierCandidate? {
        let length = digits.count
        guard length >= 5, length <= 14, length != 10 else { return nil }
        if length > 10, !Extractors.isHighConfidencePhone(digits) {
            guard !containsEmbeddedMobile(digits) else { return nil }
        }

        let tokens = original
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0).lowercased() }
        guard tokens.count >= 3 else { return nil }

        var numericTokens = 0
        var wordedTokens = 0
        for token in tokens {
            if token.allSatisfy(\.isNumber) {
                numericTokens += 1
            } else if Lex.numberWordsCore[token] != nil || Lex.numberWordsRisky[token] != nil {
                numericTokens += 1
                wordedTokens += 1
            }
        }

        guard wordedTokens >= 2 else { return nil }

        let density = Double(numericTokens) / Double(tokens.count)
        guard numericTokens >= 3, density >= 0.5 else { return nil }

        return CarrierCandidate(
            channel: "spelled number words",
            payload: digits,
            validates: false,
            shape: length < 10 ? "partial phone number" : "padded phone number"
        )
    }

    private static let runRX = try? NSRegularExpression(
        pattern: #"\d(?:[ .,\-]?\d){8,14}"#, options: []
    )

    static func contiguousMobile(in text: String) -> String? {
        guard let rx = runRX else { return nil }
        let ns = text as NSString
        var found: String? = nil
        rx.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            guard let m else { return }
            let span = ns.substring(with: m.range)
            let digits = span.filter(\.isNumber)
            guard digits.count >= 10, digits.count <= 13 else { return }
            guard !isThousandsGrouped(span) else { return }
            if Extractors.isHighConfidencePhone(String(digits)) || containsEmbeddedMobile(String(digits)) {
                found = String(digits)
                stop.pointee = true
            }
        }
        return found
    }

    static func isThousandsGrouped(_ span: String) -> Bool {
        guard span.contains(",") else { return false }
        let groups = span.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard groups.count >= 2 else { return false }
        guard let first = groups.first, first.count >= 1, first.count <= 3 else { return false }
        let rest = groups.dropFirst()
        guard let last = rest.last else { return false }
        if rest.allSatisfy({ $0.count == 3 }) { return true }
        if last.count == 3, rest.dropLast().allSatisfy({ $0.count == 2 }) { return true }
        return false
    }

    private static func containsEmbeddedMobile(_ digits: String) -> Bool {
        let chars = Array(digits)
        guard chars.count > 10 else { return false }
        for start in 0...(chars.count - 10) {
            let window = String(chars[start..<(start + 10)])
            if Extractors.isHighConfidencePhone(window) { return true }
        }
        return false
    }

    static func positionalCarriers(_ original: String) -> [CarrierCandidate] {
        var out: [CarrierCandidate] = []

        func consider(_ channel: String, _ payload: String, minimum: Int, shape: String) {
            guard payload.count >= minimum else { return }
            let digits = payload.filter(\.isNumber)
            if digits.count >= 10, Extractors.isHighConfidencePhone(String(digits)) {
                out.append(CarrierCandidate(
                    channel: channel, payload: String(digits), validates: true, shape: "phone number"
                ))
                return
            }
            let letters = payload.lowercased().filter(\.isLetter)
            guard letters.count >= minimum else { return }
            let namesPlatform = Lex.platformsStrong.contains { letters.contains($0) && $0.count >= 5 }
            if !namesPlatform {
                guard letters.count >= 7 else { return }
                let vowels = letters.filter { "aeiou".contains($0) }.count
                guard Double(vowels) / Double(letters.count) >= 0.30 else { return }
            }
            out.append(CarrierCandidate(
                channel: channel,
                payload: payload,
                validates: namesPlatform,
                shape: namesPlatform ? "platform name" : shape
            ))
        }

        let caps = PositionalChannels.capitalisedWordInitials(original)
        if caps.count >= 5, !PositionalChannels.hasMixedCasing(original) {
            consider("capitalised word initials", caps, minimum: 5, shape: "handle")
        }

        consider("repeated-punctuation run lengths", PositionalChannels.punctuationRunDigits(original),
                 minimum: 9, shape: "digit sequence")

        if let runs = repeatRunDigits(original), runs.count >= 7 {
            consider("repeated-run lengths", runs, minimum: 7, shape: "digit sequence")
        }

        return out
    }

    static func repeatRunDigits(_ s: String) -> String? {
        var out = ""
        var runCharacter: Character? = nil
        var runLength = 0

        func flush() {
            if runLength >= 1, runLength <= 9,
               let c = runCharacter, !c.isWhitespace, !c.isLetter || runLength >= 3 {
                if runLength >= 2 { out.append(Character(String(runLength))) }
            }
            runCharacter = nil
            runLength = 0
        }

        for ch in s {
            if ch == runCharacter {
                runLength += 1
            } else {
                flush()
                runCharacter = ch
                runLength = 1
            }
        }
        flush()
        return out.isEmpty ? nil : out
    }

    static let innocentFamiliarityFloor = 0.20

    static let personDirectedLead = 0.02

    static func addressesPerson(_ alpha: CharView) -> Bool {
        for token in Canonicalizer.tokenize(alpha) where token.isWord {
            if Lex.personTargets.contains(token.text) { return true }
        }
        return false
    }

    static func addressesPersonNativeScript(_ original: String) -> Bool {
        let lowered = original.lowercased()

        var hasDevanagari = false
        var hasCyrillic = false
        for scalar in lowered.unicodeScalars {
            switch scalar.value {
            case 0x0900...0x097F: hasDevanagari = true
            case 0x0400...0x04FF: hasCyrillic = true
            default: continue
            }
            if hasDevanagari && hasCyrillic { break }
        }
        guard hasDevanagari || hasCyrillic else { return false }

        let tokens = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })

        if hasDevanagari {
            for token in tokens {
                for stem in Lex.devanagariPersonStems where token.hasPrefix(stem) {
                    return true
                }
            }
        }
        if hasCyrillic {
            for token in tokens where Lex.cyrillicPersonTokens.contains(String(token)) {
                return true
            }
        }
        return false
    }

    static func nativeConditionalDemand(_ original: String) -> Bool {
        let lowered = original.lowercased()
        for cue in Lex.nativeScriptConditionalCues where lowered.contains(cue) { return true }
        return false
    }

    private static let conditionalDemandRX = RX(
        "conditional-demand",
        #"\b(?:or\s+(?:else|i|we|il+|i'?ll)|otherwise\s+i|unless\s+you|if\s+you\s+(?:do\s*n[o']?t|don'?t|refuse|won'?t)|warna|nahi\s+to|nahin\s+to|varna)\b"#
    )

    private static let conditionalReprisalRX = RX(
        "conditional-reprisal",
        #"\bif\s+you\b[^.!?]{0,60}?\bi\s*(?:will|'?ll|am\s+going\s+to|shall)\b[^.!?]{0,60}?\b(?:you|your|u\b|ur)\b"#
    )

    static func conditionalDemand(_ text: String) -> Bool {
        !conditionalDemandRX.matches(in: text, limit: 1).isEmpty
            || !conditionalReprisalRX.matches(in: text, limit: 1).isEmpty
    }

    private static let spacedDomainRX = try? NSRegularExpression(
        pattern: #"([a-z0-9][a-z0-9\-]{2,})\s+\.\s*([a-z]{2,10})\b|([a-z0-9][a-z0-9\-]{2,})\s*\.\s+([a-z]{2,10})\b"#,
        options: [.caseInsensitive]
    )

    private static let defangPatterns: [(name: String, pattern: String, minHost: Int)] = [
        ("domain split by whitespace", #"([a-z0-9][a-z0-9\-]{2,})\s*\.\s+([a-z]{2,10})"#, 3),
        ("domain split by whitespace", #"([a-z0-9][a-z0-9\-]{2,})\s+\.\s*([a-z]{2,10})"#, 3),
        ("defanged dot in brackets",   #"([a-z0-9][a-z0-9\-]{2,})\s*[\[\(\{<]\s*\.\s*[\]\)\}>]\s*([a-z]{2,10})"#, 3),
        ("dot spelled inside brackets", #"([a-z0-9][a-z0-9\-]{2,})\s*[\[\(\{<]\s*(?:dot|punto|bindu)\s*[\]\)\}>]\s*([a-z]{2,10})"#, 3),
        ("comma used as the dot",      #"([a-z0-9][a-z0-9\-]{7,}),\s*([a-z]{2,10})\b"#, 8),
        ("hyphen used as the dot",     #"([a-z0-9]{7,})-([a-z]{2,10})\b"#, 8),
    ]

    private static let compiledDefangPatterns: [(name: String, rx: NSRegularExpression, minHost: Int)] = {
        defangPatterns.compactMap { entry in
            guard let rx = try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive])
            else {
                assertionFailure("Escalation: bad defang pattern \(entry.name)")
                return nil
            }
            return (entry.name, rx, entry.minHost)
        }
    }()

    static func obfuscatedDomain(_ text: String) -> CarrierCandidate? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        for (name, rx, minHost) in compiledDefangPatterns {
            guard let match = rx.firstMatch(in: text, options: [], range: full),
                  match.numberOfRanges >= 3
            else { continue }

            let hostRange = match.range(at: 1)
            let tldRange = match.range(at: 2)
            guard hostRange.location != NSNotFound, tldRange.location != NSNotFound else { continue }

            let host = ns.substring(with: hostRange).lowercased()
            let tld = ns.substring(with: tldRange).lowercased()
            guard host.count >= minHost, Lex.commonTLDs.contains(tld) else { continue }
            guard !Lex.commonTLDs.contains(host) else { continue }
            guard !isProseContinuation(name: name, tld: tld, after: tldRange, in: ns) else { continue }

            return CarrierCandidate(
                channel: name,
                payload: "\(host).\(tld)",
                validates: true,
                shape: "domain"
            )
        }
        return nil
    }

    private static let tldsThatAreAlsoEnglishWords: Set<String> = [
        "it", "is", "in", "at", "me", "so", "to", "by", "us", "no", "as", "am", "be", "do", "my", "an",
    ]

    private static func isProseContinuation(
        name: String, tld: String, after tldRange: NSRange, in ns: NSString
    ) -> Bool {
        guard name.contains("used as the dot") else { return false }
        guard tldsThatAreAlsoEnglishWords.contains(tld) else { return false }

        let tail = tldRange.location + tldRange.length
        guard tail < ns.length else { return false }
        let remainder = ns.substring(from: tail)
        return remainder.range(of: #"^\s+[a-z]{2,}"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func wordlessProtocolCue(original: String, signals: Signals) -> Bool {
        let letters = original.filter(\.isLetter).count
        guard letters <= 24 else { return false }

        let cues: Set<Character> = ["📞", "☎", "📱", "💬", "📧", "✉", "📩", "📨", "🤙", "📲"]
        let hasCue = original.contains { cues.contains($0) }
        if hasCue { return true }

        if letters > 0, letters <= 24, signals.platformStrong {
            let words = original.split(whereSeparator: { !$0.isLetter }).count
            return words <= 3
        }
        return false
    }

    static func anomalousRegularity(_ s: String) -> Bool {
        var runLength = 0
        var previous: Character? = nil
        for ch in s {
            if ch == previous, !ch.isWhitespace {
                runLength += 1
                if runLength >= 6 { return true }
            } else {
                previous = ch
                runLength = 1
            }
        }

        let letters = s.filter(\.isLetter).count
        let emoji = s.filter { $0.unicodeScalars.first.map { $0.properties.isEmoji && $0.value > 0x238C } ?? false }.count
        if emoji >= 12, letters <= 12 { return true }

        return false
    }
}
