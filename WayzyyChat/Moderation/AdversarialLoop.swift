// Generates and grades new attack variants against the engine.

import Foundation

protocol EvasionGenerator {
    var identifier: String { get }
    func generate(count: Int) async -> [[String]]
}

struct CompositionalGenerator: EvasionGenerator {
    let identifier = "compositional-fuzzer-v1"

    private let payloads = [
        "9876543210", "8765432109", "7654321098", "9123456780", "6789012345",
    ]

    private let carriers = [
        "call me on PAYLOAD",
        "my number is PAYLOAD",
        "reach me at PAYLOAD thanks",
        "save this PAYLOAD",
        "PAYLOAD is the best way",
        "ring PAYLOAD any time",
        "text PAYLOAD when you land",
    ]

    private enum Primitive: CaseIterable {
        case spaceEveryDigit, dashEveryDigit, dotEveryTwo, commaEveryThree
        case numberWords, partialWords, hinglishWords
        case fullwidth, mathBold, circled
        case arabicIndic, devanagari
        case zeroWidth, softHyphen
        case leetLetters, embedInWords
        case reverse, chunkThenSpace
        case emojiSeparators, bracketEachDigit

        func apply(_ digits: String) -> String {
            let d = Array(digits)
            switch self {
            case .spaceEveryDigit:  return d.map(String.init).joined(separator: " ")
            case .dashEveryDigit:   return d.map(String.init).joined(separator: "-")
            case .dotEveryTwo:      return stride(from: 0, to: d.count, by: 2)
                .map { String(d[$0..<min($0 + 2, d.count)]) }.joined(separator: ".")
            case .commaEveryThree:  return stride(from: 0, to: d.count, by: 3)
                .map { String(d[$0..<min($0 + 3, d.count)]) }.joined(separator: ",")
            case .numberWords:      return d.compactMap { Self.words[$0] }.joined(separator: " ")
            case .partialWords:     return d.enumerated().map { i, c in
                i % 2 == 0 ? (Self.words[c] ?? String(c)) : String(c)
            }.joined(separator: " ")
            case .hinglishWords:    return d.compactMap { Self.hinglish[$0] }.joined(separator: " ")
            case .fullwidth:        return String(d.compactMap { Self.shift($0, by: 0xFF10 - 0x30) })
            case .mathBold:         return String(d.compactMap { Self.shift($0, by: 0x1D7CE - 0x30) })
            case .circled:          return String(d.compactMap { c -> Character? in
                guard let v = c.wholeNumberValue else { return c }
                return v == 0 ? "⓪" : Self.shift(c, by: 0x2460 - 0x31)
            })
            case .arabicIndic:      return String(d.compactMap { Self.shift($0, by: 0x0660 - 0x30) })
            case .devanagari:       return String(d.compactMap { Self.shift($0, by: 0x0966 - 0x30) })
            case .zeroWidth:        return d.map(String.init).joined(separator: "\u{200B}")
            case .softHyphen:       return d.map(String.init).joined(separator: "\u{00AD}")
            case .leetLetters:      return String(d.map { Self.leet[$0] ?? $0 })
            case .embedInWords:     return d.enumerated().map { i, c in
                i % 3 == 0 ? "a\(c)m" : String(c)
            }.joined()
            case .reverse:          return String(d.reversed())
            case .chunkThenSpace:   return stride(from: 0, to: d.count, by: 4)
                .map { String(d[$0..<min($0 + 4, d.count)]) }.joined(separator: "  ")
            case .emojiSeparators:  return d.map(String.init).joined(separator: "🔸")
            case .bracketEachDigit: return d.map { "(\($0))" }.joined()
            }
        }

        private static let words: [Character: String] = [
            "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
            "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
        ]
        private static let hinglish: [Character: String] = [
            "0": "shunya", "1": "ek", "2": "do", "3": "teen", "4": "chaar",
            "5": "paanch", "6": "chhe", "7": "saat", "8": "aath", "9": "nau",
        ]
        private static let leet: [Character: Character] = [
            "0": "O", "1": "l", "3": "E", "4": "A", "5": "S", "7": "T", "8": "B",
        ]
        private static func shift(_ c: Character, by offset: Int) -> Character? {
            guard let a = c.asciiValue, let scalar = UnicodeScalar(Int(a) + offset) else { return nil }
            return Character(scalar)
        }
    }

    func generate(count: Int) async -> [[String]] {
        var out: [[String]] = []
        var rng = SystemRandomNumberGenerator()
        let primitives = Primitive.allCases

        while out.count < count {
            let payload = payloads.randomElement(using: &rng)!
            let carrier = carriers.randomElement(using: &rng)!

            let depth = Int.random(in: 1...3, using: &rng)
            var transformed = payload
            for _ in 0..<depth {
                transformed = primitives.randomElement(using: &rng)!.apply(transformed)
            }

            let recoverable = transformed.contains { $0.isLetter || $0.isNumber }
            guard recoverable, transformed.count >= 6 else { continue }

            let message = carrier.replacingOccurrences(of: "PAYLOAD", with: transformed)

            if Int.random(in: 0..<3, using: &rng) == 0, transformed.count > 6 {
                let chars = Array(message)
                let cut = chars.count / 2
                out.append([String(chars[0..<cut]), String(chars[cut...])])
            } else {
                out.append([message])
            }
        }
        return out
    }
}

struct LLMGenerator: EvasionGenerator {
    let identifier: String
    private let judge: RemoteJudge.Configuration
    private let session: URLSession

    init(configuration: RemoteJudge.Configuration, session: URLSession = .shared) {
        self.judge = configuration
        self.session = session
        self.identifier = "llm-generator-\(configuration.model)"
    }

    private static let prompt = """
    You are red-teaming the chat moderation of a short-term rental platform. \
    Produce realistic messages a broker would send to get their phone number, \
    email or social handle to a guest without stating it plainly.

    Favour indirection and semantics over character tricks: referring to details \
    held elsewhere, arithmetic or reconstruction rules, soliciting the guest's \
    details, proposing off-platform booking or payment, or describing a scheme for \
    spreading information across messages.

    Reply with JSON only: {"attempts":[{"messages":["..."]}, ...]}
    Each attempt is one or more messages sent in order. Vary phrasing heavily.
    """

    func generate(count: Int) async -> [[String]] {
        let body: [String: Any] = [
            "model": judge.model,
            "temperature": 1.0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": Self.prompt],
                ["role": "user", "content": "Generate \(count) distinct attempts."],
            ],
        ]

        var request = URLRequest(url: judge.baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(judge.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard
            let (data, _) = try? await session.data(for: request),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String,
            let inner = content.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
            let attempts = payload["attempts"] as? [[String: Any]]
        else { return [] }

        return attempts.compactMap { $0["messages"] as? [String] }.filter { !$0.isEmpty }
    }
}

struct EscapedCase: Identifiable {
    let id = UUID()
    let messages: [String]
    let bestScore: Double
    let generator: String
    var suggestedExemplar: String { messages.joined(separator: " ") }
}

struct LoopReport {
    var generated: Int = 0
    var caught: Int = 0
    var escaped: [EscapedCase] = []
    var elapsedSeconds: Double = 0
    var generatorIdentifiers: [String] = []

    var catchRate: Double { generated == 0 ? 0 : Double(caught) / Double(generated) }
}

enum AdversarialLoop {

    static func run(
        generators: [EvasionGenerator],
        countPerGenerator: Int,
        actor: ActorContext = ActorContext(trust: .standard, stage: .inquiry)
    ) async -> LoopReport {
        let engine = ModerationEngine.shared
        var report = LoopReport()
        report.generatorIdentifiers = generators.map(\.identifier)
        let started = Date()

        for generator in generators {
            let attempts = await generator.generate(count: countPerGenerator)

            for (index, messages) in attempts.enumerated() {
                var caseActor = actor
                caseActor.conversationID = "loop-\(generator.identifier)-\(index)"
                caseActor.senderID = "adversary"
                engine.resetBuffer(actor: caseActor)

                var best = 0.0
                var enforced = false
                for message in messages {
                    let verdict = engine.evaluate(message, actor: caseActor, useConversationBuffer: true)
                    best = max(best, verdict.score)
                    if verdict.action != .allow && verdict.action != .hint { enforced = true }
                    if !verdict.action.withholdsMessage {
                        engine.remember(message, actor: caseActor)
                    }
                }

                report.generated += 1
                if enforced {
                    report.caught += 1
                } else {
                    report.escaped.append(EscapedCase(
                        messages: messages, bestScore: best, generator: generator.identifier
                    ))
                }
            }
        }

        report.elapsedSeconds = Date().timeIntervalSince(started)
        return report
    }

    static func regressionSource(for report: LoopReport, limit: Int = 40) -> String {
        var lines = ["// Auto-filed by AdversarialLoop — \(report.escaped.count) escapes"]
        for (i, escape) in report.escaped.prefix(limit).enumerated() {
            let messages = escape.messages
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: ", ")
            lines.append(
                ".init(9\(String(format: "%03d", i)), .plain, \"auto-filed\", \"phone\", [\(messages)]),"
            )
        }
        return lines.joined(separator: "\n")
    }
}
