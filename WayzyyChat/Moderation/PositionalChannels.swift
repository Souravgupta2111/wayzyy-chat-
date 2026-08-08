// Decodes covert positional carriers such as acrostics, word-length runs and list-index digits.

import Foundation

enum PositionalChannels {

    static func detect(
        original: String,
        base: CharView,
        raw: CharView,
        effort: Int
    ) -> [Detection] {
        var out: [Detection] = []
        let fullRange = 0..<max(1, Array(original).count)

        let protocolPhrase = protocolHint(in: base.text)

        if let phrase = protocolPhrase {
            out.append(Detection(
                category: .socialHandle,
                range: fullRange,
                surface: "",
                canonical: phrase,
                confidence: 0.72,
                transforms: base.transforms + ["protocol-establishment"],
                effort: effort + 4,
                reason: "Describes a decoding scheme (\"\(phrase)\") — establishing a covert channel"
            ))
        }

        var channels: [(name: String, payload: String, allowSpeculative: Bool)] = []

        let caps = capitalisedWordInitials(original)
        if caps.count >= 5, hasMixedCasing(original) {
            channels.append(("capitalised word initials", caps, true))
        }

        let midCaps = midWordCapitals(original)
        if midCaps.count >= 4 { channels.append(("mid-word capitals", midCaps, true)) }

        let lineInit = lineInitials(original)
        if lineInit.count >= 5 { channels.append(("first letter of each line", lineInit, true)) }

        let sentInit = sentenceInitials(original)
        if sentInit.count >= 5 { channels.append(("first letter of each sentence", sentInit, true)) }

        let lineWords = lineFirstWords(original)
        if lineWords.split(separator: " ").count >= 4 {
            channels.append(("first word of each line", lineWords, false))
        }

        let markup = markupIsolatedLetters(original)
        if markup.count >= 5 { channels.append(("letters isolated by markup", markup, true)) }

        let lastLetters = wordFinalLetters(original)
        if lastLetters.count >= 5 {
            channels.append(("last letter of each word", lastLetters, false))
        }

        for stride in [2, 3] {
            let strided = stridedWordInitials(original, stride: stride)
            if strided.count >= 5 {
                channels.append((
                    "every \(stride == 2 ? "second" : "third") word initial", strided, false
                ))
            }
        }

        if protocolPhrase != nil {
            let runs = punctuationRunDigits(original)
            if runs.count >= 9 {
                channels.append(("repeated-punctuation run lengths", runs, false))
            }
        }

        for channel in channels {
            if let d = classify(
                payload: channel.payload,
                channelName: channel.name,
                range: fullRange,
                transforms: base.transforms,
                effort: effort,
                anomalyPresent: channel.allowSpeculative
            ) {
                out.append(d)
                break
            }
        }

        return out
    }

    static func wordFinalLetters(_ s: String) -> String {
        var out = ""
        for token in words(s) {
            guard !isAcronymOrIdentifier(token), let last = token.last, last.isLetter else { continue }
            out.append(last)
        }
        return out
    }

    static func hasMixedCasing(_ s: String) -> Bool {
        let tokens = words(s).filter { !isAcronymOrIdentifier($0) && $0.count >= 2 }
        guard tokens.count >= 6 else { return false }
        var upper = 0, lower = 0
        for t in tokens {
            guard let f = t.first else { continue }
            if f.isUppercase { upper += 1 } else { lower += 1 }
        }
        return upper >= 4 && lower >= 2
    }

    private static func classify(
        payload: String,
        channelName: String,
        range: Range<Int>,
        transforms: [String],
        effort: Int,
        anomalyPresent: Bool
    ) -> Detection? {
        let digits = digitsFrom(payload)
        if digits.count >= 10, Extractors.isHighConfidencePhone(digits) {
            return Detection(
                category: .phone, range: range, surface: "", canonical: digits,
                confidence: 0.88, transforms: transforms + ["positional-channel"],
                effort: effort + 4,
                reason: "Phone number hidden in message structure — \(channelName)"
            )
        }

        let lowered = payload.lowercased().filter { $0.isLetter }

        for name in Lex.platformsStrong where name.count >= 5 && lowered.contains(name) {
            return Detection(
                category: .socialHandle, range: range, surface: "", canonical: name,
                confidence: 0.84, transforms: transforms + ["positional-channel"],
                effort: effort + 4,
                reason: "Platform name hidden in message structure — \(channelName)"
            )
        }

        if anomalyPresent, lowered.count >= 5, looksPronounceable(lowered) {
            return Detection(
                category: .socialHandle, range: range, surface: "", canonical: lowered,
                confidence: 0.58, transforms: transforms + ["positional-channel"],
                effort: effort + 3,
                reason: "Hidden payload suspected in message structure — \(channelName) spells \"\(lowered)\""
            )
        }

        return nil
    }

    static func capitalisedWordInitials(_ s: String) -> String {
        var out = ""
        for token in words(s) {
            guard let first = token.first, first.isUppercase else { continue }
            guard !isAcronymOrIdentifier(token) else { continue }
            out.append(first)
        }
        return out
    }

    static func midWordCapitals(_ s: String) -> String {
        var out = ""
        for token in words(s) {
            guard !isAcronymOrIdentifier(token) else { continue }
            for (i, ch) in token.enumerated() where i > 0 && ch.isUppercase {
                out.append(ch)
            }
        }
        return out
    }

    static func lineInitials(_ s: String) -> String {
        var out = ""
        for line in s.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first(where: { $0.isLetter }) else { continue }
            out.append(first)
        }
        return out
    }

    static func sentenceInitials(_ s: String) -> String {
        var out = ""
        for part in s.split(whereSeparator: { ".!?\n".contains($0) }) {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first(where: { $0.isLetter }) else { continue }
            out.append(first)
        }
        return out
    }

    static func lineFirstWords(_ s: String) -> String {
        var parts: [String] = []
        for line in s.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let word = trimmed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first
            else { continue }
            parts.append(String(word))
        }
        return parts.joined(separator: " ")
    }

    static func markupIsolatedLetters(_ s: String) -> String {
        let rx = try? NSRegularExpression(
            pattern: #"[\*\(\[\{_~]\s*([a-zA-Z])\s*[\*\)\]\}_~]"#,
            options: []
        )
        guard let rx else { return "" }
        var out = ""
        let full = NSRange(s.startIndex..<s.endIndex, in: s)
        rx.enumerateMatches(in: s, options: [], range: full) { m, _, _ in
            guard let m, m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: s) else { return }
            out += s[r]
        }
        return out
    }

    static func stridedWordInitials(_ s: String, stride: Int) -> String {
        let tokens = words(s)
        var out = ""
        var i = stride - 1
        while i < tokens.count {
            if let first = tokens[i].first, first.isLetter { out.append(first) }
            i += stride
        }
        return out
    }

    static func wordLengthDigits(_ s: String) -> String {
        var out = ""
        for token in words(s) {
            let n = token.count
            guard n >= 1, n <= 10 else { return out }
            out.append(Character(String(n % 10)))
        }
        return out
    }

    static func punctuationRunDigits(_ s: String) -> String {
        var out = ""
        var runChar: Character? = nil
        var runLength = 0

        func flush() {
            if runLength >= 1, runLength <= 10 {
                out.append(Character(String(runLength % 10)))
            }
            runLength = 0
        }

        for ch in s {
            if ch.isLetter || ch.isNumber || ch.isWhitespace {
                if runChar != nil { flush(); runChar = nil }
                continue
            }
            if ch == runChar {
                runLength += 1
            } else {
                if runChar != nil { flush() }
                runChar = ch
                runLength = 1
            }
        }
        if runChar != nil { flush() }
        return out
    }

    static func protocolHint(in loweredText: String) -> String? {
        for phrase in Lex.protocolHints where loweredText.contains(phrase) {
            return phrase
        }
        return nil
    }

    static func hasAnomalousCapitalisation(_ s: String) -> Bool {
        let tokens = words(s).filter { !isAcronymOrIdentifier($0) }
        guard tokens.count >= 5 else { return false }

        var capitalised = 0
        var midWord = 0
        for token in tokens {
            if let first = token.first, first.isUppercase { capitalised += 1 }
            for (i, ch) in token.enumerated() where i > 0 && ch.isUppercase { midWord += 1 }
        }

        if midWord >= 3 { return true }
        return Double(capitalised) / Double(tokens.count) >= 0.5
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func isAcronymOrIdentifier(_ token: String) -> Bool {
        if token.contains(where: { $0.isNumber }) { return true }
        let uppers = token.filter { $0.isUppercase }.count
        let letters = token.filter { $0.isLetter }.count
        guard letters > 0 else { return true }
        if letters <= 5, uppers >= 2 { return true }
        return Double(uppers) / Double(letters) >= 0.5 && letters > 1 && uppers > 1
    }

    private static func digitsFrom(_ payload: String) -> String {
        let view = Canonicalizer.expandNumberWords(CharView(payload.lowercased()))
        return view.text.filter { $0.isNumber }
    }

    static func looksPronounceable(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let vowels = Set("aeiou")
        var count = 0
        for (i, ch) in s.enumerated() {
            if vowels.contains(ch) { count += 1 }
            else if ch == "y", i > 0 { count += 1 }
        }
        guard count >= 1 else { return false }
        let ratio = Double(count) / Double(s.count)
        return ratio >= 0.19 && ratio <= 0.62
    }
}
