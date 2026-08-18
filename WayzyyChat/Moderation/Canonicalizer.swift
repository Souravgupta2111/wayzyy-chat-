// Builds offset-preserving character views of a message so a detection can be mapped back to the original span.

import Foundation

struct CharView {
    var chars: [Character]
    var offsets: [Int]
    var transforms: [String]

    var text: String { String(chars) }
    var isEmpty: Bool { chars.isEmpty }
    var count: Int { chars.count }

    init(_ source: String) {
        self.chars = Array(source)
        self.offsets = Array(0..<self.chars.count)
        self.transforms = []
    }

    init(chars: [Character], offsets: [Int], transforms: [String]) {
        self.chars = chars
        self.offsets = offsets
        self.transforms = transforms
    }

    func originalRange(_ start: Int, _ end: Int) -> Range<Int>? {
        guard start < end, start >= 0, end <= offsets.count else { return nil }
        let a = offsets[start]
        let b = offsets[end - 1]
        let lo = min(a, b)
        let hi = max(a, b)
        return lo..<(hi + 1)
    }

    func mapping(_ name: String, _ transform: (Character) -> String?) -> CharView {
        var outChars: [Character] = []
        var outOffsets: [Int] = []
        outChars.reserveCapacity(chars.count)
        outOffsets.reserveCapacity(chars.count)
        var changed = false

        for (i, ch) in chars.enumerated() {
            let origin = offsets[i]
            guard let replacement = transform(ch) else {
                changed = true
                continue
            }
            if replacement.count != 1 || replacement.first != ch { changed = true }
            for rc in replacement {
                outChars.append(rc)
                outOffsets.append(origin)
            }
        }

        return CharView(
            chars: outChars,
            offsets: outOffsets,
            transforms: changed ? transforms + [name] : transforms
        )
    }

    func filtering(_ name: String, _ keep: (Character) -> Bool) -> CharView {
        mapping(name) { keep($0) ? String($0) : nil }
    }
}

struct ViewToken {
    let text: String
    let start: Int
    let end: Int
    let isWord: Bool
}

struct Canonicalizer {

    struct Views {
        var raw: CharView
        var base: CharView
        var alpha: CharView
        var compact: CharView
        var alphaCompact: CharView
        var digits: CharView
        var digitsMasked: CharView
        var digitsReversed: CharView
        var separators: CharView
        var separatorsAlt: CharView
        var acrostic: CharView
        var compactDigits: CharView
        var romanDigits: CharView

        /// Devanagari transliterated to Latin, so one lexicon serves both scripts.
        var devanagariLatin: CharView
        /// Romanised-Hindi phonetic skeleton: spelling variance collapsed to a shared key.
        var hinglishSkeleton: CharView

        var allTransforms: [String] {
            var seen = Set<String>()
            var ordered: [String] = []
            for v in [raw, base, alpha, compact, alphaCompact, digits, digitsMasked,
                      digitsReversed, separators, separatorsAlt, acrostic,
                      compactDigits, romanDigits, devanagariLatin, hinglishSkeleton] {
                for t in v.transforms where !seen.contains(t) {
                    seen.insert(t)
                    ordered.append(t)
                }
            }
            return ordered
        }
    }

    static let deliberateTransforms: Set<String> = [
        "confusable-fold", "invisible-strip", "compat-fold", "emoji-digit",
        "number-words", "repeat-collapse", "nato-letters", "conversation-buffer",
        "morse-decode", "binary-decode", "hex-decode", "base64-decode", "rot13-decode",
        "percent-decode", "digit-script-fold", "numeral-script-fold",
        "hidden-carrier-decode", "roman-numerals",
        "positional-channel", "protocol-establishment",
        "separator-words",
    ]

    static func effortWeight(_ transform: String) -> Int {
        switch transform {
        case "confusable-fold", "invisible-strip", "emoji-digit": return 4
        case "morse-decode", "binary-decode", "hex-decode",
             "base64-decode", "rot13-decode", "percent-decode":   return 4
        case "hidden-carrier-decode":                             return 5
        case "positional-channel", "protocol-establishment":      return 4
        case "digit-script-fold", "numeral-script-fold":          return 4
        case "number-words", "nato-letters", "conversation-buffer": return 3
        case "compat-fold", "roman-numerals":                      return 3
        case "separator-words":                                    return 2
        case "repeat-collapse":                                    return 1
        default:                                                   return 0
        }
    }

    static func effort(for transforms: [String]) -> Int {
        transforms
            .filter { deliberateTransforms.contains($0) }
            .reduce(0) { $0 + effortWeight($1) }
    }

    static func compatibilityFold(_ ch: Character) -> String {
        let s = String(ch)
        #if canImport(Darwin)
        return s.precomposedStringWithCompatibilityMapping
        #else
        var out = ""
        for scalar in s.unicodeScalars {
            if let multi = Lex.compatibilityFallbackString(scalar) {
                out += multi
            } else if let folded = Lex.compatibilityFallback(scalar) {
                out.unicodeScalars.append(folded)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
        #endif
    }

    static func diacriticAndCaseFold(_ ch: Character) -> String {
        let s = String(ch)
        #if canImport(Darwin)
        return s.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US")
        )
        #else
        let decomposed = s.decomposedStringWithCanonicalMapping
        var kept = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars {
            let v = scalar.value
            let isCombining = (0x0300...0x036F).contains(v)
                || (0x1AB0...0x1AFF).contains(v)
                || (0x20D0...0x20FF).contains(v)
                || (0xFE20...0xFE2F).contains(v)
            if !isCombining { kept.append(scalar) }
        }
        return String(kept).lowercased()
        #endif
    }

    func build(_ original: String) -> Views {
        let raw = CharView(original)

        let compat = raw.mapping("compat-fold") { ch in
            let folded = Self.compatibilityFold(ch)
            return folded.isEmpty ? nil : folded
        }

        let decoded = compat.mapping("hidden-carrier-decode") { ch in
            let scalars = ch.unicodeScalars
            if scalars.count == 1, let s = scalars.first {
                if let tag = Lex.tagCharacter(s) { return String(tag) }
                if let ri = Lex.regionalIndicatorLetter(s) { return String(ri) }
            }
            var out = ""
            var decodedAny = false
            for s in scalars {
                if let tag = Lex.tagCharacter(s) {
                    out.append(tag)
                    decodedAny = true
                } else if let ri = Lex.regionalIndicatorLetter(s) {
                    out.append(ri)
                    decodedAny = true
                } else {
                    out.unicodeScalars.append(s)
                }
            }
            return decodedAny ? out : String(ch)
        }

        let visible = decoded.mapping("invisible-strip") { ch in
            let scalars = ch.unicodeScalars
            let kept = scalars.filter { !Lex.invisibleScalars.contains($0.value) }
            if kept.isEmpty { return nil }
            if kept.count == scalars.count { return String(ch) }
            return String(String.UnicodeScalarView(kept))
        }

        let deEmoji = visible.mapping("emoji-digit") { ch in
            if let d = Self.enclosedDigit(ch) { return String(d) }
            return String(ch)
        }

        let asciiDigits = deEmoji.mapping("digit-script-fold") { ch in
            if !ch.isASCII, ch.isWholeNumber, let v = ch.wholeNumberValue, v >= 0, v <= 9 {
                return String(v)
            }
            return String(ch)
        }

        let scriptNumerals = asciiDigits.mapping("numeral-script-fold") { ch in
            if let d = Lex.hanNumerals[ch] { return d }
            if let d = Lex.brailleDigits[ch] { return d }
            return String(ch)
        }

        let deConfused = scriptNumerals.mapping("confusable-fold") { ch in
            if let mapped = Lex.confusables[ch] { return String(mapped) }
            let lower = Character(String(ch).lowercased())
            if let mapped = Lex.confusables[lower] { return String(mapped) }
            return String(ch)
        }

        let normalized = deConfused.mapping("case-fold") { ch in
            let s = Self.diacriticAndCaseFold(ch)
            return s.isEmpty ? nil : s
        }

        let base = Self.collapseRepeats(normalized)

        let alpha = base.mapping("leet-fold") { ch in
            if let letter = Lex.leetToLetter[ch] { return String(letter) }
            return String(ch)
        }

        let compact = base.filtering("compact") { $0.isLetter || $0.isNumber }
        let alphaCompact = alpha.filtering("compact") { $0.isLetter || $0.isNumber }

        let worded = Self.expandNumberWords(base)
        let digits = worded.filtering("digits-only") { $0.isNumber }

        let contextMasked = NumericContext.mask(base)
        let maskedWorded = Self.expandNumberWords(contextMasked)
        let digitsMasked = maskedWorded.filtering("digits-only") { $0.isNumber }

        let digitsReversed = CharView(
            chars: digits.chars.reversed(),
            offsets: digits.offsets.reversed(),
            transforms: digits.transforms + ["reverse"]
        )

        let separators = Self.expandSeparatorWords(base)
        let separatorsAlt = separators.mapping("underscore-as-dot") { ch in
            ch == "_" ? "." : String(ch)
        }
        let acrostic = Self.buildAcrostic(base)

        let compactDigits = Self
            .expandNumberWords(compact)
            .filtering("digits-only") { $0.isNumber }

        let romanDigits = Self
            .expandNumberWords(Self.expandRomanNumerals(base))
            .filtering("digits-only") { $0.isNumber }

        // Devanagari to Latin. One character can expand to several ("भ" -> "bh"), and
        // mapping() replicates the source offset across the expansion, so ranges still
        // map back to the original message.
        let devanagariLatin = base.mapping("devanagari-latin") { ch in
            HinglishFold.transliterate(String(ch))
        }

        // Phonetic skeleton over the transliterated view, so romanised Hindi and
        // Devanagari collapse to the same key. Built per word to keep boundaries.
        let hinglishSkeleton = Self.buildHinglishSkeleton(devanagariLatin)

        return Views(
            raw: visible,
            base: base,
            alpha: alpha,
            compact: compact,
            alphaCompact: alphaCompact,
            digits: digits,
            digitsMasked: digitsMasked,
            digitsReversed: digitsReversed,
            separators: separators,
            separatorsAlt: separatorsAlt,
            acrostic: acrostic,
            compactDigits: compactDigits,
            romanDigits: romanDigits,
            devanagariLatin: devanagariLatin,
            hinglishSkeleton: hinglishSkeleton
        )
    }

    /// Fold each word to its phonetic skeleton while preserving word boundaries and
    /// original character offsets, so a match can still be reported against the source.
    static func buildHinglishSkeleton(_ view: CharView) -> CharView {
        var outChars: [Character] = []
        var outOffsets: [Int] = []
        var changed = false

        var wordChars: [Character] = []
        var wordOffsets: [Int] = []

        func flushWord() {
            guard !wordChars.isEmpty else { return }
            let folded = HinglishFold.skeleton(String(wordChars))
            if folded.count != wordChars.count { changed = true }
            // Attribute the whole folded word to its first source offset. Skeletons are
            // lossy by construction, so per-character attribution is not meaningful.
            let origin = wordOffsets.first ?? 0
            for c in folded {
                outChars.append(c)
                outOffsets.append(origin)
            }
            wordChars.removeAll(keepingCapacity: true)
            wordOffsets.removeAll(keepingCapacity: true)
        }

        for (i, ch) in view.chars.enumerated() {
            if ch.isLetter || ch.isNumber {
                wordChars.append(ch)
                wordOffsets.append(view.offsets[i])
            } else {
                flushWord()
                outChars.append(" ")
                outOffsets.append(view.offsets[i])
            }
        }
        flushWord()

        return CharView(
            chars: outChars,
            offsets: outOffsets,
            transforms: changed ? view.transforms + ["hinglish-skeleton"] : view.transforms
        )
    }

    static func expandRomanNumerals(_ view: CharView) -> CharView {
        let tokens = tokenize(view)
        let romanChars = Set("ivxlcdm")

        var resolved = [String?](repeating: nil, count: tokens.count)
        var runLength = 0

        for (idx, token) in tokens.enumerated() where token.isWord {
            let t = token.text
            guard !t.isEmpty, t.allSatisfy({ romanChars.contains($0) }) else { continue }
            if let digits = romanValue(t) {
                resolved[idx] = digits
                runLength += 1
            }
        }

        guard runLength >= 4 else { return view }

        var outChars: [Character] = []
        var outOffsets: [Int] = []
        for (idx, token) in tokens.enumerated() {
            if let replacement = resolved[idx] {
                let origin = view.offsets[token.start]
                for rc in replacement {
                    outChars.append(rc)
                    outOffsets.append(origin)
                }
            } else {
                for k in token.start..<token.end {
                    outChars.append(view.chars[k])
                    outOffsets.append(view.offsets[k])
                }
            }
        }

        return CharView(
            chars: outChars,
            offsets: outOffsets,
            transforms: view.transforms + ["roman-numerals"]
        )
    }

    private static func romanValue(_ token: String) -> String? {
        for (numeral, digits) in Lex.romanNumerals where numeral == token {
            return digits
        }
        return nil
    }

    static func tokenize(_ view: CharView) -> [ViewToken] {
        var tokens: [ViewToken] = []
        var i = 0
        let chars = view.chars

        while i < chars.count {
            let ch = chars[i]
            if ch.isLetter || ch.isNumber {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber { j += 1 }
                tokens.append(ViewToken(text: String(chars[i..<j]), start: i, end: j, isWord: true))
                i = j
            } else {
                tokens.append(ViewToken(text: String(ch), start: i, end: i + 1, isWord: false))
                i += 1
            }
        }
        return tokens
    }

    private static func enclosedDigit(_ ch: Character) -> Character? {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return nil }
        let v = scalar.value
        switch v {
        case 0x2460...0x2468: return Character(String(v - 0x2460 + 1))
        case 0x24EA:          return "0"
        case 0x2775...0x277D: return Character(String(v - 0x2775 + 1))
        case 0x1F10B:         return "0"
        default:              return nil
        }
    }

    private static func collapseRepeats(_ view: CharView) -> CharView {
        var outChars: [Character] = []
        var outOffsets: [Int] = []
        var run = 0
        var last: Character? = nil
        var changed = false

        for (i, ch) in view.chars.enumerated() {
            if ch == last {
                run += 1
            } else {
                run = 1
                last = ch
            }
            if run <= 2 {
                outChars.append(ch)
                outOffsets.append(view.offsets[i])
            } else {
                changed = true
            }
        }

        return CharView(
            chars: outChars,
            offsets: outOffsets,
            transforms: changed ? view.transforms + ["repeat-collapse"] : view.transforms
        )
    }

    static func expandNumberWords(_ view: CharView) -> CharView {
        let tokens = tokenize(view)
        guard !tokens.isEmpty else { return view }

        enum Resolution {
            case none
            case core(String)
            case risky(String)
            case homophone(String)
            case fuzzy(String)
            case modifier(Int)
        }

        var resolutions = [Resolution](repeating: .none, count: tokens.count)

        for (idx, token) in tokens.enumerated() where token.isWord {
            let t = token.text
            if let mult = Lex.repeatModifiers[t] {
                resolutions[idx] = .modifier(mult)
            } else if let digits = Lex.numberWordsCore[t] {
                resolutions[idx] = .core(digits)
            } else if let digits = Lex.numberWordsRisky[t] {
                resolutions[idx] = .risky(digits)
            } else if let digits = Lex.numberWordsIndic[t] {
                resolutions[idx] = .risky(digits)
            } else if let digits = Lex.numberWordsHomophones[t] {
                resolutions[idx] = .homophone(digits)
            } else if let digits = Lex.numberWordsIndicAmbiguous[t] {
                resolutions[idx] = .homophone(digits)
            } else if let digits = Lex.numberWordsFunctionWords[t] {
                resolutions[idx] = .fuzzy(digits)
            } else if let digits = Lex.numberWordsCore[Self.leetFoldToken(t)] {
                resolutions[idx] = .core(digits)
            } else if let digits = Lex.fuzzyNumberWord(t) {
                resolutions[idx] = .fuzzy(digits)
            } else if let segments = segmentNumberWords(t) {
                resolutions[idx] = .core(segments)
            } else if let mixed = segmentMixedToken(t) {
                resolutions[idx] = .core(mixed)
            }
        }

        func isNumericish(_ i: Int) -> Bool {
            guard i >= 0, i < tokens.count else { return false }
            if !tokens[i].isWord {
                return false
            }
            switch resolutions[i] {
            case .core, .risky, .homophone, .fuzzy, .modifier: return true
            case .none: return tokens[i].text.allSatisfy { $0.isNumber }
            }
        }

        func isSpelled(_ i: Int) -> Bool {
            guard i >= 0, i < tokens.count, tokens[i].isWord else { return false }
            switch resolutions[i] {
            case .core, .risky, .homophone, .fuzzy: return true
            case .none, .modifier: return false
            }
        }

        func hasSpelledNeighbour(_ i: Int) -> Bool {
            let (l, r) = neighbours(i)
            return isSpelled(l) || isSpelled(r)
        }

        func neighbours(_ i: Int) -> (Int, Int) {
            var l = i - 1
            while l >= 0, !tokens[l].isWord { l -= 1 }
            var r = i + 1
            while r < tokens.count, !tokens[r].isWord { r += 1 }
            return (l, r)
        }

        func hasNumericNeighbour(_ i: Int) -> Bool {
            let (l, r) = neighbours(i)
            return isNumericish(l) || isNumericish(r)
        }

        func exists(_ i: Int) -> Bool { i >= 0 && i < tokens.count }

        func isInsideDictation(_ i: Int) -> Bool {
            let (l, r) = neighbours(i)
            if isSpelled(l) || isSpelled(r) { return true }
            let sides = [l, r].filter(exists)
            guard !sides.isEmpty else { return false }
            return sides.allSatisfy(isNumericish)
        }

        var promoted = [String?](repeating: nil, count: tokens.count)
        for (idx, res) in resolutions.enumerated() {
            switch res {
            case .core(let d):
                promoted[idx] = d
            case .risky(let d):
                if hasNumericNeighbour(idx) { promoted[idx] = d }
            case .homophone(let d):
                if isInsideDictation(idx) { promoted[idx] = d }
            case .fuzzy(let d):
                if hasSpelledNeighbour(idx) { promoted[idx] = d }
            case .modifier, .none:
                break
            }
        }

        for (idx, res) in resolutions.enumerated() {
            guard case .modifier(let mult) = res else { continue }
            var r = idx + 1
            while r < tokens.count, !tokens[r].isWord { r += 1 }
            guard r < tokens.count else { continue }
            let following: String?
            if let p = promoted[r] { following = p }
            else if tokens[r].text.allSatisfy({ $0.isNumber }) { following = tokens[r].text }
            else { following = nil }
            if let f = following, f.count == 1 {
                promoted[r] = String(repeating: f, count: mult)
                promoted[idx] = ""
            }
        }

        var outChars: [Character] = []
        var outOffsets: [Int] = []
        var changed = false

        for (idx, token) in tokens.enumerated() {
            if let replacement = promoted[idx] {
                changed = true
                let origin = view.offsets[token.start]
                for rc in replacement {
                    outChars.append(rc)
                    outOffsets.append(origin)
                }
            } else {
                for k in token.start..<token.end {
                    outChars.append(view.chars[k])
                    outOffsets.append(view.offsets[k])
                }
            }
        }

        return CharView(
            chars: outChars,
            offsets: outOffsets,
            transforms: changed ? view.transforms + ["number-words"] : view.transforms
        )
    }

    static func leetFoldToken(_ t: String) -> String {
        guard t.contains(where: { $0.isNumber }), t.contains(where: { $0.isLetter }) else {
            return ""
        }
        return String(t.map { Lex.leetToLetter[$0] ?? $0 })
    }

    static func segmentNumberWords(_ token: String, minMatches: Int = 3) -> String? {
        guard token.count >= 4, token.allSatisfy({ $0.isLetter }) else { return nil }
        let chars = Array(token)
        let n = chars.count

        func matchAt(_ i: Int) -> (digits: String, length: Int)? {
            for len in stride(from: min(9, n - i), through: 3, by: -1) {
                if let mapped = Lex.numberWordsCore[String(chars[i..<(i + len)])] {
                    return (mapped, len)
                }
            }
            return nil
        }

        var bestDigits = ""
        var bestMatches = 0
        var runDigits = ""
        var runMatches = 0
        var i = 0

        while i < n {
            if let hit = matchAt(i) {
                runDigits += hit.digits
                runMatches += 1
                i += hit.length
            } else {
                if runMatches > bestMatches {
                    bestMatches = runMatches
                    bestDigits = runDigits
                }
                runDigits = ""
                runMatches = 0
                i += 1
            }
        }
        if runMatches > bestMatches {
            bestMatches = runMatches
            bestDigits = runDigits
        }

        return bestMatches >= minMatches ? bestDigits : nil
    }

    static func segmentMixedToken(_ token: String) -> String? {
        guard token.count >= 6 else { return nil }
        let hasLetter = token.contains { $0.isLetter }
        let hasDigit = token.contains { $0.isNumber }
        guard hasLetter, hasDigit else { return nil }

        var out = ""
        var buffer = ""
        var wordMatches = 0

        func flushLetters() -> Bool {
            guard !buffer.isEmpty else { return true }
            if let digits = Lex.numberWordsCore[buffer] {
                out += digits
                wordMatches += 1
            } else if let digits = Lex.numberWordsRisky[buffer] {
                out += digits
                wordMatches += 1
            } else if let segments = segmentNumberWords(buffer, minMatches: 1) {
                out += segments
                wordMatches += 1
            } else {
                return false
            }
            buffer = ""
            return true
        }

        for ch in token {
            if ch.isNumber {
                guard flushLetters() else { return nil }
                out.append(ch)
            } else if ch.isLetter {
                buffer.append(ch)
            } else {
                return nil
            }
        }
        guard flushLetters() else { return nil }

        return wordMatches >= 1 ? out : nil
    }

    static func expandSeparatorWords(_ view: CharView) -> CharView {
        let tokens = tokenize(view)
        var outChars: [Character] = []
        var outOffsets: [Int] = []
        var changed = false

        func wordNeighbour(_ i: Int, _ dir: Int) -> Bool {
            var k = i + dir
            while k >= 0, k < tokens.count, !tokens[k].isWord {
                if tokens[k].text.first.map({ !$0.isWhitespace && $0 != "(" && $0 != ")" && $0 != "[" && $0 != "]" && $0 != "{" && $0 != "}" }) == true {
                    return false
                }
                k += dir
            }
            guard k >= 0, k < tokens.count, tokens[k].isWord else { return false }
            return tokens[k].text.count >= 2
        }

        for (idx, token) in tokens.enumerated() {
            if token.isWord,
               let symbol = Lex.separatorWords[token.text],
               wordNeighbour(idx, -1), wordNeighbour(idx, +1) {
                changed = true
                let origin = view.offsets[token.start]
                for rc in symbol {
                    outChars.append(rc)
                    outOffsets.append(origin)
                }
            } else {
                for k in token.start..<token.end {
                    outChars.append(view.chars[k])
                    outOffsets.append(view.offsets[k])
                }
            }
        }

        let joined = CharView(
            chars: outChars,
            offsets: outOffsets,
            transforms: changed ? view.transforms + ["separator-words"] : view.transforms
        )

        let unbracketed = joined.filtering("bracket-strip") { !"[](){}<>".contains($0) }

        let sepSymbols: Set<Character> = ["@", ".", "_", "-", "/", ":", "+"]
        let chars = unbracketed.chars
        var keep = [Bool](repeating: true, count: chars.count)

        for i in chars.indices where chars[i].isWhitespace {
            var p = i - 1
            while p >= 0, chars[p].isWhitespace { p -= 1 }
            var n = i + 1
            while n < chars.count, chars[n].isWhitespace { n += 1 }

            let prevIsSep = p >= 0 && sepSymbols.contains(chars[p])
            let nextIsSep = n < chars.count && sepSymbols.contains(chars[n])
            if prevIsSep || nextIsSep { keep[i] = false }
        }

        var finalChars: [Character] = []
        var finalOffsets: [Int] = []
        for i in chars.indices where keep[i] {
            finalChars.append(chars[i])
            finalOffsets.append(unbracketed.offsets[i])
        }

        return CharView(
            chars: finalChars,
            offsets: finalOffsets,
            transforms: unbracketed.transforms
        )
    }

    static func buildAcrostic(_ view: CharView) -> CharView {
        var outChars: [Character] = []
        var outOffsets: [Int] = []

        let tokens = tokenize(view)
        for token in tokens where token.isWord {
            outChars.append(view.chars[token.start])
            outOffsets.append(view.offsets[token.start])
        }

        return CharView(chars: outChars, offsets: outOffsets, transforms: view.transforms + ["acrostic"])
    }
}
