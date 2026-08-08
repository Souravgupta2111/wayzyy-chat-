// Logistic fusion of contact-exfiltration features into one score with per-feature contributions.

import Foundation

struct Signals {
    var hasContactIntent = false
    var contactIntentPhrase: String? = nil
    var platformStrong = false
    var platformWeak = false
    var platformName: String? = nil
    var offPlatformIntent = false
    var offPlatformPhrase: String? = nil
    var paymentKeyword = false
    var mailKeyword = false
    var digitsEmbeddedInWords = 0
    var explicitAtCount = 0
    var digitCount = 0
    var characterCount = 0

    var digitDensity: Double {
        characterCount == 0 ? 0 : Double(digitCount) / Double(characterCount)
    }

    static func compute(base: CharView, alpha: CharView, compact: CharView) -> Signals {
        var s = Signals()
        let text = base.text
        let alphaCompactText = alpha.filtering("x") { $0.isLetter }.text

        s.characterCount = base.count
        s.digitCount = base.chars.reduce(0) { $0 + ($1.isNumber ? 1 : 0) }
        s.explicitAtCount = base.chars.reduce(0) { $0 + ($1 == "@" ? 1 : 0) }

        for phrase in Lex.contactIntent where text.contains(phrase) {
            s.hasContactIntent = true
            s.contactIntentPhrase = phrase
            break
        }
        for phrase in Lex.offPlatformIntent where text.contains(phrase) {
            s.offPlatformIntent = true
            s.offPlatformPhrase = phrase
            break
        }

        let tokens = Canonicalizer.tokenize(alpha)
        for token in tokens where token.isWord {
            let t = token.text
            if Lex.platformsStrong.contains(t) {
                s.platformStrong = true
                s.platformName = t
            } else if Lex.platformsWeak.contains(t) {
                s.platformWeak = true
                if s.platformName == nil { s.platformName = t }
            }
            if Lex.paymentKeywords.contains(t) { s.paymentKeyword = true }
            if ["mail", "email", "emailid", "gmail", "inbox", "id", "address",
                "yahoo", "outlook", "hotmail", "icloud", "protonmail"].contains(t) {
                s.mailKeyword = true
            }
        }

        if !s.platformStrong {
            let compactText = compact.text
            for p in Lex.platformsStrong where p.count >= 5 && compactText.contains(p) {
                s.platformStrong = true
                s.platformName = p
                break
            }
        }
        if !s.mailKeyword {
            for kw in ["gmail", "email", "mailid", "emailid"] where alphaCompactText.contains(kw) {
                s.mailKeyword = true
                break
            }
        }

        for token in tokens where token.isWord {
            let t = token.text
            guard t.count >= 3 else { continue }
            let letters = t.filter { $0.isLetter }.count
            let digits = t.filter { $0.isNumber }.count
            if letters >= 2, digits >= 1, !t.allSatisfy({ $0.isNumber }) {
                s.digitsEmbeddedInWords += 1
            }
        }

        return s
    }
}

struct Scorer {

    struct Weights {
        var bias = -3.55
        var maxConfidence = 4.30
        var detectionCount = 0.34
        var obfuscationEffort = 2.45
        var contactIntent = 1.52
        var platformStrong = 1.02
        var platformWeak = 0.42
        var offPlatformIntent = 1.34
        var paymentKeyword = 0.58
        var digitsEmbedded = 1.14
        var suppressedOnly = -1.62
        var crossMessage = 1.70
        var priorViolations = 0.82
        var explicitAt = 0.46
        var digitDensity = 0.70

        static let `default` = Weights()
    }

    struct Input {
        var detections: [Detection]
        var signals: Signals
        var obfuscationEffort: Int
        var suppressedOnly: Bool
        var crossMessageAssembled: Bool
        var priorViolations: Int
    }

    struct Output {
        let score: Double
        let features: [(String, Double)]
        let contributions: [(String, Double)]
    }

    let weights: Weights

    init(weights: Weights = .default) {
        self.weights = weights
    }

    func score(_ input: Input) -> Output {
        let w = weights
        let s = input.signals

        let maxConf = input.detections.map(\.confidence).max() ?? 0
        let countNorm = min(Double(input.detections.count), 3.0) / 3.0
        let effortNorm = min(Double(input.obfuscationEffort), 12.0) / 12.0
        let embeddedNorm = min(Double(s.digitsEmbeddedInWords), 3.0) / 3.0
        let atNorm = min(Double(s.explicitAtCount), 2.0) / 2.0
        let priorNorm = min(Double(input.priorViolations), 3.0) / 3.0
        let densityNorm = min(s.digitDensity * 3.0, 1.0)

        let terms: [(String, Double, Double)] = [
            ("bias", 1, w.bias),
            ("candidate confidence", maxConf, w.maxConfidence),
            ("candidate count", countNorm, w.detectionCount),
            ("obfuscation effort", effortNorm, w.obfuscationEffort),
            ("contact-intent phrase", s.hasContactIntent ? 1 : 0, w.contactIntent),
            ("platform keyword (strong)", s.platformStrong ? 1 : 0, w.platformStrong),
            ("platform keyword (weak)", s.platformWeak ? 1 : 0, w.platformWeak),
            ("off-platform framing", s.offPlatformIntent ? 1 : 0, w.offPlatformIntent),
            ("payment keyword", s.paymentKeyword ? 1 : 0, w.paymentKeyword),
            ("digits inside words", embeddedNorm, w.digitsEmbedded),
            ("legit numeric context", input.suppressedOnly ? 1 : 0, w.suppressedOnly),
            ("assembled across messages", input.crossMessageAssembled ? 1 : 0, w.crossMessage),
            ("prior violations", priorNorm, w.priorViolations),
            ("explicit @", atNorm, w.explicitAt),
            ("digit density", densityNorm, w.digitDensity),
        ]

        var logit = 0.0
        var features: [(String, Double)] = []
        var contributions: [(String, Double)] = []

        for (name, value, weight) in terms {
            let contribution = value * weight
            logit += contribution
            if name != "bias" { features.append((name, value)) }
            if abs(contribution) > 0.001 { contributions.append((name, contribution)) }
        }

        let probability = 1.0 / (1.0 + exp(-logit))
        return Output(
            score: probability,
            features: features,
            contributions: contributions.sorted { abs($0.1) > abs($1.1) }
        )
    }
}
