// Fans Tier-3 requests across several judges to raise effective throughput.

import Foundation

final class PooledJudge: SemanticJudge {

    let identifier: String
    private let judges: [RemoteJudge]
    private let lock = NSLock()
    private var next = 0

    init(apiKey: String, models: [String], timeout: TimeInterval = 60) {
        precondition(!models.isEmpty, "PooledJudge needs at least one model")
        self.judges = models.map { model in
            var c = RemoteJudge.Configuration.groq(apiKey: apiKey, model: model)
            c.timeout = timeout
            c.breakerEnabled = false
            c.maxCallsPerMinute = 3_000
            c.maxCallsPerDay = 100_000
            return RemoteJudge(configuration: c, allowModelFallback: false)
        }
        self.identifier = "pool(\(models.count) lanes)"
    }

    var laneCount: Int { judges.count }

    private func lease() -> RemoteJudge {
        lock.lock()
        defer { lock.unlock() }
        let judge = judges[next % judges.count]
        next += 1
        return judge
    }

    private static let tokensPerCall = 1_300
    private static let laneTokensPerMinute = 8_000

    var sustainableCallsPerSecond: Double {
        Double(judges.count) * Double(Self.laneTokensPerMinute)
            / Double(Self.tokensPerCall) / 60.0
    }

    func judge(_ request: JudgeRequest) async -> JudgeVerdict {
        var attempted = 0
        var last: JudgeVerdict? = nil
        while attempted < judges.count {
            let lane = lease()
            attempted += 1
            let verdict = await lane.judge(request)
            if !(verdict.decision == .abstain && verdict.confidence == 0) {
                return verdict
            }
            last = verdict
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return last ?? JudgeVerdict(
            decision: .abstain, confidence: 0,
            rationale: "All \(judges.count) lanes failed.",
            intent: nil, source: identifier, latencyMs: 0
        )
    }
}

extension ModerationEngine {
    @discardableResult
    func configurePooledJudge(
        models: [String] = RemoteJudge.Configuration.groqSchemaCompliantModels
    ) -> Bool {
        guard let key = SecretsStore.groq, !key.isEmpty else { return false }
        judge = PooledJudge(apiKey: key, models: models)
        return true
    }
}
