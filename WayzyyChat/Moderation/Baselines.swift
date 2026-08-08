// Regex-only and hybrid baselines used to measure what each tier actually adds.

import Foundation

enum Baseline: String, CaseIterable, Identifiable {
    case regexOnly = "Regex only"
    case hybrid    = "Hybrid (T1+T2)"
    case llmOnly   = "LLM only"

    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .regexOnly:
            return "Patterns for phone, email, URL and handle, plus a digit-count rule. No normalisation, no context."
        case .hybrid:
            return "Canonicalisation + deterministic extraction + retrieval. In-process, no network."
        case .llmOnly:
            return "Every message to a policy-grounded LLM. Requires a key; measured live."
        }
    }
}

enum RegexBaseline {

    private static let patterns: [(String, NSRegularExpression?)] = {
        func rx(_ p: String) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        return [
            ("phone", rx(#"(?:\+?\d[\d\s.\-()]{8,16}\d)"#)),
            ("email", rx(#"[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}"#)),
            ("url",   rx(#"(?:https?://|www\.)\S+"#)),
            ("domain", rx(#"\b[a-z0-9\-]{2,}\.(?:com|net|org|in|me|io|co)\b"#)),
            ("handle", rx(#"@[a-z0-9._]{3,30}"#)),
            ("platform", rx(#"\b(?:whatsapp|whatsap|instagram|insta|telegram|snapchat|signal|viber|wechat|skype|messenger)\b"#)),
            ("digitrun", rx(#"\d{7,}"#)),
        ]
    }()

    static func flags(_ text: String) -> (flagged: Bool, rule: String?) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for (name, pattern) in patterns {
            guard let pattern else { continue }
            if pattern.firstMatch(in: text, options: [], range: range) != nil {
                return (true, name)
            }
        }
        return (false, nil)
    }
}

struct BaselineOutcome: Identifiable {
    let id = UUID()
    let baseline: Baseline
    var truePositives = 0
    var falseNegatives = 0
    var trueNegatives = 0
    var falsePositives = 0
    var latencies: [Double] = []
    var errors = 0
    var unavailableReason: String? = nil

    var positives: Int { truePositives + falseNegatives }
    var negatives: Int { trueNegatives + falsePositives }
    var recall: Double { positives == 0 ? 0 : Double(truePositives) / Double(positives) }
    var precision: Double {
        let d = truePositives + falsePositives
        return d == 0 ? 0 : Double(truePositives) / Double(d)
    }
    var falsePositiveRate: Double { negatives == 0 ? 0 : Double(falsePositives) / Double(negatives) }
    var p50: Double {
        guard !latencies.isEmpty else { return 0 }
        let s = latencies.sorted()
        return s[s.count / 2]
    }
    var evaluated: Int { positives + negatives }
}

struct ComparisonReport {
    var outcomes: [BaselineOutcome] = []
    var corpusSize: Int = 0
    var startedAt = Date()
}

enum BaselineComparison {

    struct Item {
        let text: String
        let shouldFlag: Bool
    }

    static func corpus(limit: Int? = nil) -> [Item] {
        var items: [Item] = []
        for c in RedTeamCorpus.all where !c.isSequence {
            items.append(Item(text: c.messages[0], shouldFlag: true))
        }
        for c in AdversarialSuite.allCases where !c.shouldFlag {
            items.append(Item(text: c.text, shouldFlag: false))
        }
        if let limit, items.count > limit {
            let pos = items.filter(\.shouldFlag).prefix(limit * 2 / 3)
            let neg = items.filter { !$0.shouldFlag }.prefix(limit / 3)
            return Array(pos) + Array(neg)
        }
        return items
    }

    static func runLocal() -> ComparisonReport {
        let items = corpus()
        var report = ComparisonReport()
        report.corpusSize = items.count

        var regex = BaselineOutcome(baseline: .regexOnly)
        var hybrid = BaselineOutcome(baseline: .hybrid)
        let engine = ModerationEngine.shared

        for item in items {
            var t0 = DispatchTime.now().uptimeNanoseconds
            let r = RegexBaseline.flags(item.text)
            regex.latencies.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            record(&regex, flagged: r.flagged, shouldFlag: item.shouldFlag)

            t0 = DispatchTime.now().uptimeNanoseconds
            let v = engine.evaluate(item.text, useConversationBuffer: false)
            hybrid.latencies.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            record(&hybrid, flagged: v.action != .allow && v.action != .hint, shouldFlag: item.shouldFlag)
        }

        var llm = BaselineOutcome(baseline: .llmOnly)
        llm.unavailableReason = SecretsStore.hasAnyProvider
            ? "Not run yet — tap Measure LLM (rate-limited, ~4 s per call on the free tier)."
            : "No API key configured. Add one to Secrets.json at the project root."

        report.outcomes = [regex, hybrid, llm]
        return report
    }

    static func measureLLM(
        sampleSize: Int = 24,
        pacing: TimeInterval = 4.5,
        progress: @escaping (Int, Int) -> Void
    ) async -> BaselineOutcome {
        var outcome = BaselineOutcome(baseline: .llmOnly)
        guard let configuration = RemoteJudge.Configuration.fromSecrets() else {
            outcome.unavailableReason = "No API key configured."
            return outcome
        }
        var measurementConfig = configuration
        measurementConfig.breakerEnabled = false
        let judge = RemoteJudge(configuration: measurementConfig)
        let items = Array(corpus(limit: sampleSize))

        for (i, item) in items.enumerated() {
            progress(i + 1, items.count)
            let t0 = DispatchTime.now().uptimeNanoseconds
            let verdict = await judge.judge(JudgeRequest(
                window: [item.text],
                priorScore: 0,
                priorFindings: [],
                bookingStage: .inquiry,
                trust: .standard
            ))
            outcome.latencies.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)

            switch verdict.decision {
            case .abstain:
                outcome.errors += 1
                record(&outcome, flagged: false, shouldFlag: item.shouldFlag)
            case .exfiltration, .safetyViolation:
                record(&outcome, flagged: true, shouldFlag: item.shouldFlag)
            case .benign:
                record(&outcome, flagged: false, shouldFlag: item.shouldFlag)
            }

            if i < items.count - 1 {
                try? await Task.sleep(nanoseconds: UInt64(pacing * 1_000_000_000))
            }
        }
        if outcome.errors > 0 {
            outcome.unavailableReason = judge.lastFailure
        }
        return outcome
    }

    private static func record(_ o: inout BaselineOutcome, flagged: Bool, shouldFlag: Bool) {
        switch (shouldFlag, flagged) {
        case (true, true):   o.truePositives += 1
        case (true, false):  o.falseNegatives += 1
        case (false, true):  o.falsePositives += 1
        case (false, false): o.trueNegatives += 1
        }
    }
}
