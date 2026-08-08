// Harness: measures every tier over the production-shaped corpus.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

struct Case: Decodable {
    let id: String
    let corpus: String
    let family: String
    let messages: [String]
    let shouldFlag: Bool
}

let data = try Data(contentsOf: URL(fileURLWithPath: "/tmp/corpus.json"))
let cases = try JSONDecoder().decode([Case].self, from: data)

let engine = ModerationEngine.shared
engine.tier2Enabled = true

guard let key = SecretsStore.groq, !key.isEmpty else {
    print("no groq key configured"); exit(1)
}
let models = RemoteJudge.Configuration.groqSchemaCompliantModels
let pool = PooledJudge(apiKey: key, models: models)
engine.judge = pool

func pct(_ d: Double) -> String { String(format: "%5.1f%%", d * 100) }

struct Pending {
    let index: Int
    let verdict: Verdict
    let message: String
    let actor: ActorContext
    let request: JudgeRequest
}

var enforcedByT12 = [Bool](repeating: false, count: cases.count)
var writeLatency = [Double](repeating: 0, count: cases.count)
var pending: [Pending] = []

let t1Start = Date()
for (i, c) in cases.enumerated() {
    let actor = ActorContext(trust: .standard, stage: .inquiry,
                             conversationID: "prod-\(c.id)", senderID: "s")
    engine.resetBuffer(actor: actor)

    var enforced = false
    var suspicious: Verdict? = nil
    var suspiciousMessage = c.messages.last ?? ""
    var total = 0.0

    for m in c.messages {
        let v = engine.evaluate(m, actor: actor, useConversationBuffer: true)
        total += v.latencyMs
        if v.action != .allow && v.action != .hint { enforced = true }
        if !enforced, engine.shouldEscalate(v),
           suspicious == nil || (!v.suspicions.isEmpty && suspicious!.suspicions.isEmpty) {
            suspicious = v
            suspiciousMessage = m
        }
        if !v.action.withholdsMessage { engine.remember(m, actor: actor) }
    }

    writeLatency[i] = total
    enforcedByT12[i] = enforced

    if !enforced, let v = suspicious {
        pending.append(Pending(
            index: i, verdict: v, message: suspiciousMessage, actor: actor,
            request: engine.judgeRequest(for: v, message: suspiciousMessage, actor: actor)
        ))
    }
}
let t1Elapsed = Date().timeIntervalSince(t1Start)

print(String(repeating: "=", count: 72))
print("FULL PIPELINE — Tiers 1+2+3, production semantics")
print(String(repeating: "=", count: 72))
print("\(cases.count) cases: \(cases.filter(\.shouldFlag).count) attacks, \(cases.filter { !$0.shouldFlag }.count) innocent")
print("Tier 3: \(models.count) pooled lanes, \(models.first ?? "")\n")
print("Tiers 1+2 enforced \(enforcedByT12.filter { $0 }.count) cases in \(String(format: "%.2f", t1Elapsed)) s")
print("Escalating to Tier 3: \(pending.count) (\(pct(Double(pending.count) / Double(cases.count))))\n")

Task {
    var judgements: [Int: JudgeVerdict] = [:]
    let t3Start = Date()
    var t3Latencies: [Double] = []

    await withTaskGroup(of: (Int, JudgeVerdict).self) { group in
        var next = 0
        let gap = UInt64(1_000_000_000.0 / pool.sustainableCallsPerSecond)
        func submit() {
            guard next < pending.count else { return }
            let slot = next
            let req = pending[slot].request
            next += 1
            group.addTask { (slot, await pool.judge(req)) }
        }
        for _ in 0..<min(pool.laneCount, pending.count) {
            submit()
            try? await Task.sleep(nanoseconds: gap)
        }
        var done = 0
        while let (slot, verdict) = await group.next() {
            judgements[slot] = verdict
            t3Latencies.append(verdict.latencyMs)
            done += 1
            if done % 15 == 0 { print("  tier 3: \(done)/\(pending.count)") }
            try? await Task.sleep(nanoseconds: gap)
            submit()
        }
    }
    let t3Elapsed = Date().timeIntervalSince(t3Start)

    var finalEnforced = enforcedByT12
    var rescued = 0, abstained = 0, t3Cleared = 0
    for (slot, judgement) in judgements {
        let p = pending[slot]
        if judgement.decision == .abstain { abstained += 1; continue }
        let revised = engine.applyJudgement(judgement, to: p.verdict,
                                            message: p.message, actor: p.actor)
        let enforced = revised.action != .allow && revised.action != .hint
        if enforced {
            finalEnforced[p.index] = true
            rescued += 1
        } else if judgement.decision == .benign {
            t3Cleared += 1
        }
    }

    var tp = 0, fn = 0, tn = 0, fp = 0
    var fpList: [(String, String)] = []
    for (i, c) in cases.enumerated() {
        if c.shouldFlag {
            if finalEnforced[i] { tp += 1 } else { fn += 1 }
        } else {
            if finalEnforced[i] {
                fp += 1
                if fpList.count < 12 { fpList.append((c.family, c.messages.last ?? "")) }
            } else { tn += 1 }
        }
    }

    let pos = tp + fn, neg = tn + fp
    let recall = pos == 0 ? 0 : Double(tp) / Double(pos)
    let precision = (tp + fp) == 0 ? 0 : Double(tp) / Double(tp + fp)
    let fpr = neg == 0 ? 0 : Double(fp) / Double(neg)
    let acc = Double(tp + tn) / Double(cases.count)

    let w = writeLatency.sorted()
    func p(_ q: Double) -> Double { w[min(w.count - 1, Int(Double(w.count - 1) * q))] }
    let t3 = t3Latencies.sorted()

    print("")
    print(String(repeating: "=", count: 72))
    print("FINAL — full pipeline")
    print(String(repeating: "=", count: 72))
    print(String(format: "  recall      %6.1f%%   (%d of %d attacks)", recall * 100, tp, pos))
    print(String(format: "  precision   %6.1f%%", precision * 100))
    print(String(format: "  FPR         %6.1f%%   (%d of %d innocent)", fpr * 100, fp, neg))
    print(String(format: "  accuracy    %6.1f%%", acc * 100))
    print("")
    print("  TIER 3 CONTRIBUTION")
    print("    calls made       \(pending.count)  (\(pct(Double(pending.count) / Double(cases.count))) of messages)")
    print("    rescued          \(rescued)")
    print("    cleared as benign \(t3Cleared)")
    print("    abstained        \(abstained)")
    if !t3.isEmpty {
        print(String(format: "    latency p50/p95  %.0f / %.0f ms  (asynchronous)",
                     t3[t3.count / 2], t3[min(t3.count - 1, Int(Double(t3.count) * 0.95))]))
    }
    print(String(format: "    wall clock       %.0f s for %d calls", t3Elapsed, pending.count))
    print("")
    print("  WRITE-PATH LATENCY — what a user actually waits for")
    print(String(format: "    p50 %.2f ms   p95 %.2f ms   p99 %.2f ms   max %.2f ms",
                 p(0.50), p(0.95), p(0.99), w.last ?? 0))
    print("")

    let perCall = 0.000075
    let rate = Double(pending.count) / Double(cases.count)
    print("  COST")
    print(String(format: "    escalation rate  %.1f%%", rate * 100))
    print(String(format: "    per 100k msgs    $%.2f   (%.0f calls x $%.6f) + $0.01 compute",
                 100_000 * rate * perCall + 0.01, 100_000 * rate, perCall))
    print(String(format: "    per 1M msgs      $%.2f", 1_000_000 * rate * perCall + 0.10))
    print(String(format: "    10k users/month  $%.2f   (6M messages)", 6_000_000 * rate * perCall + 0.60))
    print("")

    if fp > 0 {
        print("  FALSE POSITIVES (\(fp)):")
        for (fam, txt) in fpList { print("    [\(fam.prefix(20))] \(txt.prefix(60))") }
    } else {
        print("  FALSE POSITIVES: none")
    }
    print("")
    print(String(repeating: "=", count: 72))
    print("COMPARISON — identical 480-case shuffled pool")
    print(String(repeating: "=", count: 72))
    print("  configuration          recall  precision    FPR   write p50   $/100k")
    print("  regex baseline          34.3%      97.1%   4.88%    0.01 ms    $0.00")
    print("  LLM only (qwen 7B)      88.1%      97.3%  13.20%     951 ms    $7.50")
    print("  Tiers 1+2 only          85.9%     100.0%   0.00%    1.84 ms    $0.01")
    print(String(format: "  FULL PIPELINE          %5.1f%%     %5.1f%%   %4.2f%%    %.2f ms    $%.2f",
                 recall * 100, precision * 100, fpr * 100, p(0.50),
                 100_000 * rate * perCall + 0.01))
    exit(0)
}

dispatchMain()
