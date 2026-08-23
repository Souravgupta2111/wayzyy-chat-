// Deterministic extraction of phones, emails, URLs, social handles, payment rails and encoded carriers.

import Foundation

struct OffsetTable {
    private let map: [String.Index: Int]

    init(_ text: String) {
        var m: [String.Index: Int] = [:]
        m.reserveCapacity(text.count + 1)
        var i = 0
        var idx = text.startIndex
        while idx < text.endIndex {
            m[idx] = i
            i += 1
            idx = text.index(after: idx)
        }
        m[text.endIndex] = i
        self.map = m
    }

    func offset(_ index: String.Index) -> Int? { map[index] }
}

struct RX {
    private let rx: NSRegularExpression
    let name: String

    init(_ name: String, _ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) {
        self.name = name
        self.rx = (try? NSRegularExpression(pattern: pattern, options: options))
            ?? (try! NSRegularExpression(pattern: "(?!)"))
    }

    struct Match {
        let start: Int
        let end: Int
        let text: String
        let groups: [String]
    }

    func matches(in text: String, limit: Int = 64, offsets: OffsetTable? = nil) -> [Match] {
        guard !text.isEmpty else { return [] }
        var out: [Match] = []
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let table = offsets ?? OffsetTable(text)

        rx.enumerateMatches(in: text, options: [], range: full) { m, _, stop in
            guard let m, let r = Range(m.range, in: text) else { return }
            guard let start = table.offset(r.lowerBound),
                  let end = table.offset(r.upperBound) else { return }
            var groups: [String] = []
            if m.numberOfRanges > 1 {
                for gi in 1..<m.numberOfRanges {
                    if let gr = Range(m.range(at: gi), in: text) {
                        groups.append(String(text[gr]))
                    } else {
                        groups.append("")
                    }
                }
            }
            out.append(Match(start: start, end: end, text: String(text[r]), groups: groups))
            if out.count >= limit { stop.pointee = true }
        }
        return out
    }
}

enum Extractors {

    static let clockAmbiguous: Set<String> = ["pm", "am"]

    static func originalSpanIsNumeric(_ range: Range<Int>, in base: CharView) -> Bool {
        var sawDigit = false
        for (i, offset) in base.offsets.enumerated() where range.contains(offset) {
            let ch = base.chars[i]
            if ch.isNumber { sawDigit = true }
            else if ch.isLetter { return false }
        }
        return sawDigit
    }

    private struct PhoneShape {
        let e164: String
        let confidence: Double
        let note: String
    }

    static func isHighConfidencePhone(_ digits: String) -> Bool {
        guard let shape = validate(digits) else { return false }
        return shape.confidence >= 0.85
    }

    private static func validate(_ digits: String) -> PhoneShape? {
        let d = Array(digits)
        guard d.count >= 8, d.count <= 15 else { return nil }

        func indianMobile(_ s: ArraySlice<Character>) -> Bool {
            guard s.count == 10, let f = s.first else { return false }
            return "6789".contains(f)
        }

        if d.count == 12, d[0] == "9", d[1] == "1", indianMobile(d[2...]) {
            return PhoneShape(e164: "+\(digits)", confidence: 0.95, note: "IN mobile with country code")
        }
        if d.count == 11, d[0] == "0", indianMobile(d[1...]) {
            return PhoneShape(e164: "+91\(String(d[1...]))", confidence: 0.90, note: "IN mobile with trunk prefix")
        }
        if d.count == 14, d.starts(with: ["0", "0", "9", "1"]), indianMobile(d[4...]) {
            return PhoneShape(e164: "+91\(String(d[4...]))", confidence: 0.93, note: "IN mobile, IDD prefix")
        }
        if indianMobile(d[0...]) {
            return PhoneShape(e164: "+91\(digits)", confidence: 0.92, note: "IN mobile")
        }
        if d.count == 11, d[0] == "1", let a = d[safe: 1], "23456789".contains(a) {
            return PhoneShape(e164: "+\(digits)", confidence: 0.74, note: "NANP with country code")
        }
        if d.count == 10, let a = d.first, "23456789".contains(a) {
            return PhoneShape(e164: "+1\(digits)", confidence: 0.62, note: "possible NANP")
        }
        if d.count >= 11, d.count <= 15 {
            return PhoneShape(e164: "+\(digits)", confidence: 0.50, note: "generic E.164 shape")
        }
        if d.count == 9 || d.count == 8 {
            return PhoneShape(e164: digits, confidence: 0.34, note: "short / landline shape")
        }
        return nil
    }

    static func phones(
        digitView: CharView,
        suppressed: Bool,
        effort: Int,
        reversed: Bool = false,
        spanMultiplier: Int = 7
    ) -> [Detection] {
        let digits = digitView.text
        guard digits.count >= 8 else { return [] }

        struct Candidate {
            let start: Int
            let end: Int
            let shape: PhoneShape
            let range: Range<Int>
        }

        var candidates: [Candidate] = []
        let n = digits.count
        let chars = Array(digits)

        let candidateCap = 400

        outer: for length in [14, 12, 11, 10] where length <= n {
            for start in 0...(n - length) {
                if candidates.count >= candidateCap { break outer }
                let slice = String(chars[start..<(start + length)])
                guard let shape = validate(slice), shape.confidence >= 0.50 else { continue }
                guard let orig = digitView.originalRange(start, start + length) else { continue }

                let allowedWidth = length * spanMultiplier + 16
                guard orig.count <= allowedWidth else { continue }

                candidates.append(Candidate(start: start, end: start + length, shape: shape, range: orig))
            }
        }

        guard !candidates.isEmpty else { return [] }

        candidates.sort { lhs, rhs in
            if lhs.shape.confidence != rhs.shape.confidence {
                return lhs.shape.confidence > rhs.shape.confidence
            }
            return (lhs.end - lhs.start) > (rhs.end - rhs.start)
        }

        var taken: [Range<Int>] = []
        var out: [Detection] = []

        for c in candidates {
            if taken.contains(where: { $0.overlaps(c.start..<c.end) }) { continue }
            taken.append(c.start..<c.end)

            var confidence = c.shape.confidence
            if suppressed { confidence *= 0.55 }
            if reversed { confidence *= 0.85 }

            var note = c.shape.note
            if reversed { note += ", written in reverse" }
            if suppressed { note += "; overlaps a legitimate numeric context" }

            out.append(Detection(
                category: .phone,
                range: c.range,
                surface: "",
                canonical: c.shape.e164,
                confidence: min(confidence, 0.99),
                transforms: digitView.transforms,
                effort: effort,
                reason: note
            ))
            if out.count >= 4 { break }
        }

        return out
    }

    private static let emailRX = RX(
        "email",
        #"[a-z0-9][a-z0-9._%+\-]{1,63}@[a-z0-9][a-z0-9\-]{0,62}(?:\.[a-z]{2,24})+"#
    )

    static func emails(base: CharView, separators: CharView, hasMailKeyword: Bool, effort: Int) -> [Detection] {
        var out: [Detection] = []
        var seen = Set<String>()

        for m in emailRX.matches(in: base.text) {
            guard let orig = base.originalRange(m.start, m.end) else { continue }
            guard seen.insert(m.text).inserted else { continue }
            out.append(Detection(
                category: .email,
                range: orig,
                surface: "",
                canonical: m.text,
                confidence: 0.96,
                transforms: base.transforms,
                effort: effort,
                reason: "Literal email address"
            ))
        }

        if hasMailKeyword {
            for m in emailRX.matches(in: separators.text) {
                guard let orig = separators.originalRange(m.start, m.end) else { continue }
                guard seen.insert(m.text).inserted else { continue }
                out.append(Detection(
                    category: .email,
                    range: orig,
                    surface: "",
                    canonical: m.text,
                    confidence: 0.88,
                    transforms: separators.transforms,
                    effort: effort + 2,
                    reason: "Email reconstructed from spelled-out separators"
                ))
            }
        }

        return out
    }

    /// Reconstructs `local@host.tld` from "sunny dot k at gmail dot com" across one
    /// message or a joined conversation window.
    static func spelledEmails(in text: String, effort: Int) -> [Detection] {
        var s = " \(text.lowercased()) "
        for (word, symbol) in [
            (" dot ", "."), (" dawt ", "."), (" point ", "."), (" period ", "."),
            (" at ", "@"), (" aht ", "@"), (" atsign ", "@"),
            (" underscore ", "_"),
        ] {
            s = s.replacingOccurrences(of: word, with: symbol)
        }
        s = s.replacingOccurrences(of: " @", with: "@")
        s = s.replacingOccurrences(of: "@ ", with: "@")
        s = s.replacingOccurrences(of: " .", with: ".")
        s = s.replacingOccurrences(of: ". ", with: ".")
        var out: [Detection] = []
        var seen = Set<String>()
        for m in emailRX.matches(in: s) {
            guard seen.insert(m.text).inserted else { continue }
            out.append(Detection(
                category: .email,
                range: 0..<max(1, text.count),
                surface: "",
                canonical: m.text,
                confidence: 0.90,
                transforms: ["spelled-separators"],
                effort: effort + 2,
                reason: "Email reconstructed from spelled-out separators"
            ))
        }
        return out
    }

    private static let urlRX = RX(
        "url",
        #"(?:https?://|www\.)[a-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]{3,}"#
    )
    private static let bareDomainRX = RX(
        "bare-domain",
        #"\b([a-z0-9][a-z0-9\-]{0,40})\.([a-z]{2,12})(?:/[^\s]{0,60})?\b"#
    )

    private static let ownDomains: Set<String> = ["wayzyy.com", "wayzyy.in", "wayzyy"]

    private static func classifyURL(_ raw: String, explicitScheme: Bool) -> (ModCategory, Double, String)? {
        let lowered = raw.lowercased()
        let host = lowered
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
            .split(separator: "/").first.map(String.init) ?? lowered

        // Operator allowlist wins outright: this deployment's own hosts are not external.
        if ownDomains.contains(host) || URLReputation.isAllowlisted(host: host) { return nil }

        // Shape first. Reputation is consulted afterwards and may only raise the result,
        // so a reputation feed can never talk the engine out of a shape-based finding.
        var shapeConfidence: Double? = nil
        var shapeReason: String? = nil

        if Lex.shorteners.contains(host) {
            shapeConfidence = 0.94
            shapeReason = "Known link-shortener or deep-link host"
        } else if host.contains("xn--") {
            shapeConfidence = 0.92
            shapeReason = "Punycode domain — deliberately obscured host"
        } else {
            let tld = host.split(separator: ".").last.map(String.init) ?? ""
            if Lex.commonTLDs.contains(tld) {
                shapeConfidence = 0.68
                shapeReason = "External link"
            } else if explicitScheme,
                      host.contains("."),
                      tld.count >= 2, tld.count <= 24,
                      tld.allSatisfy({ $0.isLetter }) {
                shapeConfidence = 0.68
                shapeReason = "External link — scheme present, TLD outside allowlist"
            }
        }

        guard let (conf, why) = URLReputation.adjust(host: host,
                                                     shapeConfidence: shapeConfidence,
                                                     shapeReason: shapeReason)
        else { return nil }
        return (.externalURL, conf, why)
    }

    static func urls(base: CharView, effort: Int) -> [Detection] {
        var out: [Detection] = []
        var seen = Set<String>()

        for m in urlRX.matches(in: base.text) {
            guard let (cat, conf, why) = classifyURL(m.text, explicitScheme: true),
                  let orig = base.originalRange(m.start, m.end),
                  seen.insert(m.text).inserted else { continue }
            out.append(Detection(
                category: cat, range: orig, surface: "", canonical: m.text,
                confidence: conf, transforms: base.transforms, effort: effort, reason: why
            ))
        }

        for m in bareDomainRX.matches(in: base.text) {
            guard let (cat, conf, why) = classifyURL(m.text, explicitScheme: false),
                  let orig = base.originalRange(m.start, m.end),
                  seen.insert(m.text).inserted else { continue }
            out.append(Detection(
                category: cat, range: orig, surface: "", canonical: m.text,
                confidence: conf * 0.9, transforms: base.transforms, effort: effort,
                reason: why + " (bare domain)"
            ))
        }

        return out
    }

    static func spelledURLs(in text: String, effort: Int) -> [Detection] {
        var s = " \(text.lowercased()) "
        for (word, symbol) in [
            (" dot ", "."), (" dawt ", "."), (" point ", "."), (" period ", ".")
        ] {
            s = s.replacingOccurrences(of: word, with: symbol)
        }
        s = s.replacingOccurrences(of: " .", with: ".")
        s = s.replacingOccurrences(of: ". ", with: ".")
        
        var out: [Detection] = []
        var seen = Set<String>()
        
        for m in bareDomainRX.matches(in: s) {
            guard let (cat, conf, why) = classifyURL(m.text, explicitScheme: false),
                  seen.insert(m.text).inserted else { continue }
            out.append(Detection(
                category: cat, range: 0..<max(1, text.count), surface: "", canonical: m.text,
                confidence: conf, transforms: ["spelled-separators"], effort: effort + 3,
                reason: why + " (spelled-out domain)"
            ))
        }
        
        return out
    }

    private static let atHandleRX = RX("at-handle", #"@([a-z0-9](?:[a-z0-9._]){2,29})\b"#)

    private static let possessives: Set<String> = [
        "my", "mine", "our", "ours", "mera", "meri", "mere", "hamara", "hamari",
    ]

    private static let handleNouns: Set<String> = [
        "handle", "handles", "id", "ids", "username", "user", "profile",
        "account", "page", "channel", "dm", "dms",
    ]

    private static let copulas: Set<String> = ["is", "are", "hai", "hain", "ho", "was"]

    static func adjectivalPlatforms(in text: String) -> Set<String> {
        guard text.contains("-") else { return [] }
        var out: Set<String> = []
        let lowered = text.lowercased()
        for tail in Lex.compoundAdjectiveTails {
            var from = lowered.startIndex
            while let r = lowered.range(of: "-" + tail, range: from..<lowered.endIndex) {
                let endsWord = r.upperBound == lowered.endIndex
                    || !(lowered[r.upperBound].isLetter || lowered[r.upperBound].isNumber)
                if endsWord {
                    var i = r.lowerBound
                    var head = ""
                    while i > lowered.startIndex {
                        let prev = lowered.index(before: i)
                        guard lowered[prev].isLetter || lowered[prev].isNumber else { break }
                        head.insert(lowered[prev], at: head.startIndex)
                        i = prev
                    }
                    if head.count >= 2 { out.insert(head) }
                }
                from = r.upperBound
            }
        }
        return out
    }

    private static let connectives: Set<String> = [
        "is", "handle", "user", "username", "name", "account", "profile", "id",
        "same", "also", "here", "there", "this", "that", "check", "follow", "add",
        "message", "text", "call", "reach", "contact", "find", "search", "please",
        "thanks", "cheers", "mine", "yours", "my", "the", "and", "you", "your",
        "will", "can", "could", "would", "just", "then", "about", "with", "from",
    ]

    private static let handleShapeRX = RX(
        "handle-shape",
        #"\b[a-z][a-z0-9]{0,20}(?:[._][a-z0-9]{1,20}){1,8}\b"#
    )

    /// Mail hosts are platforms for email reconstruction, not Instagram-style handles.
    private static let mailHosts: Set<String> = [
        "gmail", "yahoo", "hotmail", "outlook", "protonmail", "icloud", "rediff",
        "mail", "email", "proton",
    ]

    static func handles(
        base: CharView,
        alpha: CharView,
        effort: Int,
        hasContactIntent: Bool
    ) -> [Detection] {
        var out: [Detection] = []
        var seen = Set<String>()

        let baseText = base.text
        let platformPositions: [(String, Int)] = {
            var found: [(String, Int)] = []
            for p in Lex.platformsStrong where p.count >= 4 {
                var searchStart = baseText.startIndex
                while let r = baseText.range(of: p, range: searchStart..<baseText.endIndex) {
                    found.append((p, baseText.distance(from: baseText.startIndex, to: r.upperBound)))
                    searchStart = r.upperBound
                    if found.count > 8 { break }
                }
            }
            return found
        }()

        if !platformPositions.isEmpty {
            for m in handleShapeRX.matches(in: baseText) {
                let tail = m.text.split(separator: ".").last.map(String.init) ?? ""
                if Lex.commonTLDs.contains(tail) { continue }
                guard m.text.contains("_") || m.text.filter({ $0 == "." }).count >= 2 else { continue }

                let near = platformPositions.contains { _, end in
                    m.start >= end - 4 && m.start - end <= 24
                }
                guard near,
                      let orig = base.originalRange(m.start, m.end),
                      seen.insert(m.text).inserted else { continue }

                out.append(Detection(
                    category: .socialHandle, range: orig, surface: "", canonical: m.text,
                    confidence: 0.87, transforms: base.transforms, effort: effort,
                    reason: "Separator-obfuscated handle near a platform keyword"
                ))
            }
        }

        for m in atHandleRX.matches(in: base.text) {
            let handle = m.groups.first ?? ""
            let tail = handle.split(separator: ".").last.map(String.init) ?? ""
            if Lex.commonTLDs.contains(tail) { continue }
            if Lex.upiSuffixes.contains(tail) { continue }
            guard let orig = base.originalRange(m.start, m.end),
                  seen.insert(handle).inserted else { continue }
            out.append(Detection(
                category: .socialHandle, range: orig, surface: "", canonical: "@\(handle)",
                confidence: 0.86, transforms: base.transforms, effort: effort,
                reason: "Explicit social handle"
            ))
        }

        let tokens = Canonicalizer.tokenize(alpha)
        let wordIdx = tokens.indices.filter { tokens[$0].isWord }
        let adjectival = Self.adjectivalPlatforms(in: base.text)

        for (pos, idx) in wordIdx.enumerated() {
            let token = tokens[idx].text
            guard Lex.framedPlatforms.contains(token)
                    || Lex.platformsStrong.contains(token)
                    || Lex.platformsWeak.contains(token) else { continue }
            guard !Self.mailHosts.contains(token) else { continue }
            guard !adjectival.contains(token) else { continue }

            var cursor = pos + 1
            var sawHandleNoun = false
            if cursor < wordIdx.count, Self.handleNouns.contains(tokens[wordIdx[cursor]].text) {
                sawHandleNoun = true
                cursor += 1
            }
            let possessive = pos > 0 && Self.possessives.contains(tokens[wordIdx[pos - 1]].text)
            guard possessive || sawHandleNoun else { continue }

            if cursor < wordIdx.count, Self.copulas.contains(tokens[wordIdx[cursor]].text) {
                cursor += 1
            }
            guard cursor < wordIdx.count else { continue }

            let cand = tokens[wordIdx[cursor]]
            let t = cand.text
            guard t.count >= 4, t.count <= 30,
                  t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }),
                  !Self.connectives.contains(t),
                  !Self.handleNouns.contains(t),
                  !Lex.identifierStoplist.contains(t),
                  !Lex.compoundAdjectiveTails.contains(t),
                  Lex.fuzzyPlatform(t) == nil,
                  !Lex.framedPlatforms.contains(t) else { continue }
            guard let orig = alpha.originalRange(cand.start, cand.end),
                  seen.insert(t).inserted else { continue }
            out.append(Detection(
                category: .socialHandle, range: orig, surface: "", canonical: t,
                confidence: 0.86, transforms: alpha.transforms, effort: effort,
                reason: "Identifier shared in an explicit \"\(token)\" frame"
            ))
        }

        for (pos, idx) in wordIdx.enumerated() {
            let token = tokens[idx].text
            let isStrong = Lex.platformsStrong.contains(token)
            let isWeak = Lex.platformsWeak.contains(token)
            guard isStrong || isWeak else { continue }
            guard !Self.mailHosts.contains(token) else { continue }

            guard !adjectival.contains(token) else { continue }

            if Lex.genericWordPlatforms.contains(token), !hasContactIntent {
                let window = max(0, pos - 2)...min(wordIdx.count - 1, pos + 2)
                let corroborated = window.contains { other in
                    other != pos && Lex.looksLikeHandle(tokens[wordIdx[other]].text)
                }
                if !corroborated { continue }
            }

            if Self.clockAmbiguous.contains(token), pos > 0 {
                let previousToken = tokens[wordIdx[pos - 1]]
                if let orig = alpha.originalRange(previousToken.start, previousToken.end),
                   Self.originalSpanIsNumeric(orig, in: base) {
                    continue
                }
            }

            let lo = max(0, pos - 3)
            let hi = min(wordIdx.count - 1, pos + 5)
            var found = false

            for other in lo...hi where other != pos {
                let cand = tokens[wordIdx[other]]
                guard Lex.looksLikeHandle(cand.text) else { continue }
                guard let orig = alpha.originalRange(cand.start, cand.end),
                      seen.insert(cand.text).inserted else { continue }
                out.append(Detection(
                    category: .socialHandle, range: orig, surface: "", canonical: cand.text,
                    confidence: isStrong ? 0.88 : 0.70,
                    transforms: alpha.transforms, effort: effort,
                    reason: "Handle-shaped token next to \"\(token)\""
                ))
                found = true
                break
            }

            if !found {
                let lo2 = max(0, pos - 1)
                let hi2 = min(wordIdx.count - 1, pos + 3)
                for other in lo2...hi2 where other != pos {
                    let cand = tokens[wordIdx[other]]
                    let t = cand.text
                    guard t.count >= 5, t.count <= 30, t.allSatisfy({ $0.isLetter || $0.isNumber })
                    else { continue }
                    guard !Self.connectives.contains(t),
                          !Lex.compoundAdjectiveTails.contains(t),
                          Lex.fuzzyPlatform(t) == nil else { continue }
                    guard let orig = alpha.originalRange(cand.start, cand.end),
                          seen.insert(t).inserted else { continue }
                    out.append(Detection(
                        category: .socialHandle, range: orig, surface: "", canonical: t,
                        confidence: isStrong ? 0.84 : 0.68,
                        transforms: alpha.transforms, effort: effort,
                        reason: "Identifier introduced by \"\(token)\""
                    ))
                    found = true
                    break
                }
            }

            // Do not emit the platform token itself as a handle. "my insta is" /
            // "at gmail" are frames for a later identifier, not the identifier.
        }

        return out
    }

    static func platformSteering(
        base: CharView,
        alpha: CharView,
        compact: CharView,
        alphaCompact: CharView,
        hasContactIntent: Bool,
        offPlatformIntent: Bool,
        effort: Int
    ) -> [Detection] {
        var best: (range: Range<Int>, name: String, how: String)? = nil

        func compactMatchIsCredible(orig: Range<Int>, matchLength: Int, in reference: CharView) -> Bool {
            if orig.count > matchLength { return true }

            func originalCharacter(at index: Int) -> Character? {
                guard index >= 0, let k = reference.offsets.firstIndex(of: index) else { return nil }
                return reference.chars[k]
            }
            if let before = originalCharacter(at: orig.lowerBound - 1),
               before.isLetter || before.isNumber { return false }
            if let after = originalCharacter(at: orig.upperBound),
               after.isLetter || after.isNumber { return false }
            return true
        }

        for token in Canonicalizer.tokenize(alpha) where token.isWord {
            let t = token.text
            let stripped = Lex.platformsStripped.contains(t)
            let fuzzy = Lex.fuzzyPlatform(t)
            guard stripped || fuzzy != nil else { continue }
            if Lex.genericWordPlatforms.contains(t), !hasContactIntent, !offPlatformIntent {
                continue
            }
            if let orig = alpha.originalRange(token.start, token.end) {
                let how: String
                if stripped {
                    how = "vowel-stripped spelling"
                } else if let fuzzy, fuzzy != t {
                    how = "platform name misspelled as \"\(t)\""
                } else {
                    how = "platform name"
                }
                best = (orig, fuzzy ?? t, how)
                break
            }
        }

        if best == nil {
            for view in [compact, alphaCompact] {
                let text = view.text
                guard text.count >= 4 else { continue }
                for name in Lex.platformsStrong where name.count >= 5 {
                    guard let r = text.range(of: name) else { continue }
                    let lo = text.distance(from: text.startIndex, to: r.lowerBound)
                    let hi = text.distance(from: text.startIndex, to: r.upperBound)
                    if let orig = view.originalRange(lo, hi),
                       compactMatchIsCredible(orig: orig, matchLength: name.count, in: alpha) {
                        best = (orig, name, "platform name with separators removed")
                        break
                    }
                }
                if best != nil { break }
            }
        }

        if best == nil {
            let uncollapsed = alphaCompact.text
            let collapsed = Lex.collapseRuns(uncollapsed)
            for name in Lex.platformsCollapsed where name.count >= 5 {
                guard collapsed.contains(name), !uncollapsed.contains(name) else { continue }
                let upper = min(alphaCompact.offsets.last.map { $0 + 1 } ?? 1, 400)
                best = (0..<max(1, upper), name, "platform name with repeated letters")
                break
            }
        }

        if let found = best, Self.adjectivalPlatforms(in: base.text).contains(found.name) {
            best = nil
        }

        guard let hit = best else { return [] }

        let confidence: Double
        if hasContactIntent || offPlatformIntent {
            confidence = 0.88
        } else {
            confidence = 0.72
        }

        return [Detection(
            category: .socialHandle,
            range: hit.range,
            surface: "",
            canonical: hit.name,
            confidence: confidence,
            transforms: base.transforms,
            effort: effort,
            reason: "Steering to an off-platform channel — \(hit.how)"
        )]
    }

    static func leetDigitRuns(base: CharView, compact: CharView, effort: Int) -> [Detection] {
        var out: [Detection] = []
        var seen = Set<String>()

        func scan(_ view: CharView) {
            let chars = view.chars
            var i = 0

            while i < chars.count {
                var j = i
                var digits = ""
                var letterCount = 0
                while j < chars.count {
                    let ch = chars[j]
                    if ch.isNumber {
                        digits.append(ch)
                    } else if let mapped = Lex.letterToDigit[ch]
                        ?? Lex.letterToDigit[Character(String(ch).lowercased())] {
                        digits.append(mapped)
                        letterCount += 1
                    } else {
                        break
                    }
                    j += 1
                }

                var transitions = 0
                if j > i {
                    for k in (i + 1)..<j where chars[k].isNumber != chars[k - 1].isNumber {
                        transitions += 1
                    }
                }

                if digits.count >= 10, letterCount >= 2, transitions >= 4 {
                    let d = Array(digits)
                    var matched = false
                    for length in [12, 11, 10] where length <= d.count {
                        for start in 0...(d.count - length) {
                            let candidate = String(d[start..<(start + length)])
                            guard isHighConfidencePhone(candidate) else { continue }
                            guard let orig = view.originalRange(i + start, i + start + length),
                                  seen.insert(candidate).inserted else { continue }
                            out.append(Detection(
                                category: .phone, range: orig, surface: "",
                                canonical: "+91\(candidate)", confidence: 0.90,
                                transforms: view.transforms + ["reverse-leet"],
                                effort: effort,
                                reason: "Phone number written with digits substituted as letters"
                            ))
                            matched = true
                            break
                        }
                        if matched { break }
                    }
                }

                i = max(j, i + 1)
            }
        }

        scan(base)
        scan(compact)
        return out
    }

    private static let dottedIdentRX = RX(
        "ident-dotted",
        #"\b[a-z][a-z0-9]{1,24}(?:[._][a-z0-9]{1,24}){1,6}\b"#
    )
    private static let mixedIdentRX = RX(
        "ident-mixed",
        #"\b(?=[a-z0-9]*[a-z])(?=[a-z0-9]*\d)[a-z][a-z0-9]{3,29}\b"#
    )

    /// Locator / PNR shape: mixed letters and digits, hyphens ok, no handle separators.
    /// `traveler.k.29` and `sunny_go` stay handles. `MT3AD9C8` and `GPX-MT3AD9C8` do not.
    static func looksLikeBookingLocator(_ token: String) -> Bool {
        let t = token.hasPrefix("@") ? String(token.dropFirst()) : token
        guard t.count >= 5, t.count <= 20 else { return false }
        guard t.contains(where: \.isNumber), t.contains(where: \.isLetter) else { return false }
        if t.contains(".") || t.contains("_") || t.contains("@") { return false }
        
        var maxLetters = 0
        var currentLetters = 0
        for ch in t {
            if ch.isLetter {
                currentLetters += 1
                maxLetters = max(maxLetters, currentLetters)
            } else {
                currentLetters = 0
            }
        }
        
        // Locators rarely have 5 or more consecutive letters. Handlers/names often do.
        if maxLetters >= 5 { return false }
        
        return t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    static func bareIdentifiers(
        base: CharView,
        wordTokenCount: Int,
        hasContactIntent: Bool,
        effort: Int
    ) -> [Detection] {
        var out: [Detection] = []
        var seen = Set<String>()
        let text = base.text

        let proseAllowed = wordTokenCount <= 4 || hasContactIntent

        func alphaPrefix(_ s: String) -> String {
            String(s.prefix { $0.isLetter })
        }

        for rx in [dottedIdentRX, mixedIdentRX] {
            for m in rx.matches(in: text, limit: 6) {
                let token = m.text
                guard token.count >= 4, token.count <= 32 else { continue }
                guard token.filter({ $0.isLetter }).count >= 3 else { continue }
                let underscored = token.contains("_")
                let separated = token.contains(".") || underscored
                guard proseAllowed || underscored else { continue }
                // Mixed alnum with no separator is a booking locator as often as a handle.
                // Our improved looksLikeBookingLocator handles this distinction.
                if looksLikeBookingLocator(token), !hasContactIntent { continue }

                let tail = token.split(separator: ".").last.map(String.init) ?? ""
                if Lex.commonTLDs.contains(tail) || Lex.upiSuffixes.contains(tail) { continue }

                let prefix = alphaPrefix(token)
                if Lex.identifierStoplist.contains(prefix) { continue }
                if Lex.numberWordsCore[prefix] != nil { continue }

                guard let orig = base.originalRange(m.start, m.end),
                      seen.insert(token).inserted else { continue }

                out.append(Detection(
                    category: .socialHandle,
                    range: orig,
                    surface: "",
                    canonical: token,
                    confidence: hasContactIntent ? 0.84 : 0.74,
                    transforms: base.transforms,
                    effort: effort,
                    reason: hasContactIntent
                        ? "Identifier-shaped token alongside an explicit request to connect"
                        : "Message is little more than an identifier-shaped token"
                ))
            }
        }

        if wordTokenCount <= 3, proseAllowed {
            let tokens = Canonicalizer.tokenize(base).filter(\.isWord)
            for token in tokens {
                let t = token.text
                let strong = Lex.platformsStrong.contains(t)
                let weak = Lex.platformsWeak.contains(t)
                guard strong || weak else { continue }
                guard let orig = base.originalRange(token.start, token.end),
                      seen.insert("platform-only-\(t)").inserted else { continue }
                out.append(Detection(
                    category: .socialHandle,
                    range: orig,
                    surface: "",
                    canonical: t,
                    confidence: strong ? 0.80 : 0.72,
                    transforms: base.transforms,
                    effort: effort,
                    reason: "Platform name sent on its own — a request to move off-platform"
                ))
            }
        }

        return out
    }

    private static let vpaRX = RX("vpa", #"\b([a-z0-9][a-z0-9._\-]{2,40})@([a-z]{2,24})\b"#)
    private static let ifscRX = RX("ifsc", #"\b([a-z]{4}0[a-z0-9]{6})\b"#)
    private static let acctRX = RX("acct", #"\b(?:a\/c|acc(?:ount)?|acct)\D{0,10}(\d{9,18})\b"#)
    private static let btcRX = RX("btc", #"\b([13][a-km-zA-HJ-NP-Z1-9]{25,34})\b"#, [])
    private static let bech32RX = RX("bech32", #"\b(bc1[a-z0-9]{25,62})\b"#)
    private static let ethRX = RX("eth", #"\b(0x[a-f0-9]{40})\b"#)
    private static let tronRX = RX("tron", #"\b(T[A-Za-z0-9]{33})\b"#, [])

    static func payments(base: CharView, raw: CharView, hasPaymentKeyword: Bool, effort: Int) -> [Detection] {
        var out: [Detection] = []

        for m in vpaRX.matches(in: base.text) {
            let suffix = m.groups.count > 1 ? m.groups[1] : ""
            let known = Lex.upiSuffixes.contains(suffix)
            guard known || (hasPaymentKeyword && !Lex.commonTLDs.contains(suffix)) else { continue }
            guard let orig = base.originalRange(m.start, m.end) else { continue }
            out.append(Detection(
                category: .paymentHandle, range: orig, surface: "", canonical: m.text,
                confidence: known ? 0.95 : 0.74,
                transforms: base.transforms, effort: effort,
                reason: known ? "UPI virtual payment address" : "Payment handle near payment keyword"
            ))
        }

        for m in ifscRX.matches(in: base.text) {
            guard hasPaymentKeyword, let orig = base.originalRange(m.start, m.end) else { continue }
            out.append(Detection(
                category: .bankDetails, range: orig, surface: "", canonical: m.text,
                confidence: 0.88, transforms: base.transforms, effort: effort,
                reason: "IFSC code"
            ))
        }

        for m in acctRX.matches(in: base.text) {
            guard let orig = base.originalRange(m.start, m.end) else { continue }
            out.append(Detection(
                category: .bankDetails, range: orig, surface: "", canonical: m.text,
                confidence: 0.86, transforms: base.transforms, effort: effort,
                reason: "Bank account number"
            ))
        }

        for rx in [btcRX, bech32RX, ethRX, tronRX] {
            for m in rx.matches(in: raw.text) {
                guard let orig = raw.originalRange(m.start, m.end) else { continue }
                out.append(Detection(
                    category: .cryptoAddress, range: orig, surface: "", canonical: m.text,
                    confidence: 0.92, transforms: raw.transforms, effort: effort,
                    reason: "Cryptocurrency address (\(rx.name))"
                ))
            }
        }

        return out
    }

    static func encoded(raw: CharView, base: CharView, effort: Int) -> [Detection] {
        var out: [Detection] = []
        let tokens = Canonicalizer.tokenize(raw)

        let morseRX = RX("morse", #"(?:[.\-]{1,6}[ /|]+){3,}[.\-]{1,6}"#, [])
        for m in morseRX.matches(in: raw.text) {
            let decoded = decodeMorse(m.text)
            guard decoded.count >= 6, let cat = quickScan(decoded),
                  let orig = raw.originalRange(m.start, m.end) else { continue }
            out.append(Detection(
                category: cat, range: orig, surface: "", canonical: decoded,
                confidence: 0.90, transforms: raw.transforms + ["morse-decode"],
                effort: effort, reason: "Morse-encoded \(cat.display.lowercased())"
            ))
        }

        let binRX = RX("binary", #"(?:[01]{8}[ ,]*){4,}"#, [])
        for m in binRX.matches(in: raw.text) {
            let decoded = decodeBinary(m.text)
            guard let cat = quickScan(decoded), let orig = raw.originalRange(m.start, m.end) else { continue }
            out.append(Detection(
                category: cat, range: orig, surface: "", canonical: decoded,
                confidence: 0.92, transforms: raw.transforms + ["binary-decode"],
                effort: effort, reason: "Binary-encoded \(cat.display.lowercased())"
            ))
        }

        for token in tokens where token.isWord && token.text.count >= 8 {
            let t = token.text
            guard let orig = raw.originalRange(token.start, token.end) else { continue }

            if t.count % 2 == 0, t.count >= 14, t.allSatisfy({ $0.isHexDigit }) {
                let decoded = decodeHex(t)
                if let cat = quickScan(decoded) {
                    out.append(Detection(
                        category: cat, range: orig, surface: "", canonical: decoded,
                        confidence: 0.90, transforms: raw.transforms + ["hex-decode"],
                        effort: effort, reason: "Hex-encoded \(cat.display.lowercased())"
                    ))
                    continue
                }
            }

            let hasUpper = t.contains { $0.isUppercase }
            let hasLower = t.contains { $0.isLowercase }
            if t.count >= 12, (hasUpper && hasLower) || t.contains(where: { $0.isNumber }) {
                if let data = Data(base64Encoded: padBase64(t)),
                   let decoded = String(data: data, encoding: .utf8),
                   let cat = quickScan(decoded) {
                    out.append(Detection(
                        category: cat, range: orig, surface: "", canonical: decoded,
                        confidence: 0.91, transforms: raw.transforms + ["base64-decode"],
                        effort: effort, reason: "Base64-encoded \(cat.display.lowercased())"
                    ))
                    continue
                }
            }
        }

        if raw.text.contains("%") {
            let decoded = percentDecode(raw.text)
            if decoded != raw.text, let cat = quickScan(decoded) {
                let upper = min(raw.offsets.last.map { $0 + 1 } ?? 1, 400)
                out.append(Detection(
                    category: cat, range: 0..<max(1, upper), surface: "", canonical: decoded,
                    confidence: 0.90, transforms: raw.transforms + ["percent-decode"],
                    effort: effort, reason: "Percent-encoded \(cat.display.lowercased())"
                ))
            }
        }

        if quickScan(base.text) == nil, !looksLikeProse(base.text) {
            var found = false
            for shift in 1...25 {
                let candidate = caesar(base.text, shift)
                guard let cat = quickScan(candidate, minPlatformLength: 5) else { continue }
                let upper = min(base.offsets.last.map { $0 + 1 } ?? 1, 400)
                out.append(Detection(
                    category: cat, range: 0..<max(1, upper), surface: "", canonical: candidate,
                    confidence: shift == 13 ? 0.80 : 0.74,
                    transforms: base.transforms + ["rot13-decode"],
                    effort: effort,
                    reason: shift == 13
                        ? "ROT13-encoded \(cat.display.lowercased())"
                        : "Caesar-shift(\(shift)) \(cat.display.lowercased())"
                ))
                found = true
                break
            }

            if !found {
                let flipped = atbash(base.text)
                if let cat = quickScan(flipped) {
                    let upper = min(base.offsets.last.map { $0 + 1 } ?? 1, 400)
                    out.append(Detection(
                        category: cat, range: 0..<max(1, upper), surface: "", canonical: flipped,
                        confidence: 0.74, transforms: base.transforms + ["rot13-decode"],
                        effort: effort, reason: "Atbash-encoded \(cat.display.lowercased())"
                    ))
                }
            }
        }

        let natoWords = tokens.filter { $0.isWord }.compactMap { Lex.natoAlphabet[$0.text] != nil ? $0 : nil }
        if natoWords.count >= 4,
           let first = natoWords.first, let last = natoWords.last,
           let orig = base.originalRange(first.start, last.end) {
            let spelled = String(natoWords.compactMap { Lex.natoAlphabet[$0.text] })
            out.append(Detection(
                category: .socialHandle, range: orig, surface: "", canonical: spelled,
                confidence: 0.82, transforms: base.transforms + ["nato-letters"],
                effort: effort + 4, reason: "Identifier spelled in NATO phonetic alphabet"
            ))
        }

        return out
    }

    private static func quickScan(_ s: String, minPlatformLength: Int = 3) -> ModCategory? {
        guard s.count >= 6, s.count < 400 else { return nil }
        let lowered = s.lowercased()
        guard lowered.allSatisfy({ $0.isASCII }) else { return nil }

        if !emailRX.matches(in: lowered, limit: 1).isEmpty { return .email }

        let digits = lowered.filter { $0.isNumber }
        if digits.count >= 10, validate(String(digits.prefix(12))) != nil || validate(String(digits.prefix(10))) != nil {
            return .phone
        }
        for p in Lex.platformsStrong
        where p.count >= minPlatformLength && lowered.contains(p) {
            return .socialHandle
        }
        return nil
    }

    private static let stopwords: Set<String> = [
        "the", "is", "a", "an", "to", "for", "you", "and", "my", "it", "in", "on",
        "at", "of", "this", "that", "we", "be", "was", "were", "have", "has",
        "will", "if", "not", "are", "your", "our", "with", "from", "can", "but",
        "so", "do", "no", "yes", "please", "thanks", "there", "here", "all",
    ]

    private static func looksLikeProse(_ s: String) -> Bool {
        let tokens = s.lowercased().split { !$0.isLetter }
        var hits = 0
        for t in tokens where stopwords.contains(String(t)) {
            hits += 1
            if hits >= 2 { return true }
        }
        return false
    }

    private static func padBase64(_ s: String) -> String {
        let rem = s.count % 4
        return rem == 0 ? s : s + String(repeating: "=", count: 4 - rem)
    }

    private static func decodeHex(_ s: String) -> String {
        let chars = Array(s)
        var bytes: [UInt8] = []
        var i = 0
        while i + 1 < chars.count {
            if let b = UInt8(String(chars[i...(i + 1)]), radix: 16) { bytes.append(b) }
            i += 2
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func decodeBinary(_ s: String) -> String {
        let groups = s.split(whereSeparator: { !"01".contains($0) })
        var bytes: [UInt8] = []
        for g in groups where g.count == 8 {
            if let b = UInt8(String(g), radix: 2) { bytes.append(b) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func decodeMorse(_ s: String) -> String {
        let letters = s.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "|" })
        return String(letters.compactMap { Lex.morseToChar[String($0)] })
    }

    private static func caesar(_ s: String, _ shift: Int) -> String {
        let k = UInt8(shift % 26)
        return String(s.map { ch -> Character in
            guard let a = ch.asciiValue else { return ch }
            if a >= 97, a <= 122 { return Character(UnicodeScalar((a - 97 + k) % 26 + 97)) }
            if a >= 65, a <= 90 { return Character(UnicodeScalar((a - 65 + k) % 26 + 65)) }
            return ch
        })
    }

    private static func atbash(_ s: String) -> String {
        String(s.map { ch -> Character in
            guard let a = ch.asciiValue else { return ch }
            if a >= 97, a <= 122 { return Character(UnicodeScalar(122 - (a - 97))) }
            if a >= 65, a <= 90 { return Character(UnicodeScalar(90 - (a - 65))) }
            return ch
        })
    }

    private static func percentDecode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
