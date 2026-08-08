// Harness: measures the Tier 1 plus Tier 2 configuration alone.

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

var tp = 0, fn = 0, tn = 0, fp = 0
var latencies: [Double] = []
var escalated = 0
var fpList: [(String, String)] = []
var fnList: [(String, String)] = []

for c in cases {
    let actor = ActorContext(trust: .standard, stage: .inquiry,
                             conversationID: "mix-\(c.id)", senderID: "s")
    engine.resetBuffer(actor: actor)

    var enforced = false
    var wouldEscalate = false
    var total = 0.0
    for m in c.messages {
        let v = engine.evaluate(m, actor: actor, useConversationBuffer: true)
        total += v.latencyMs
        if v.action != .allow && v.action != .hint { enforced = true }
        if engine.shouldEscalate(v) { wouldEscalate = true }
        if !v.action.withholdsMessage { engine.remember(m, actor: actor) }
    }
    latencies.append(total)
    if !enforced && wouldEscalate { escalated += 1 }

    if c.shouldFlag {
        if enforced { tp += 1 } else {
            fn += 1
            if fnList.count < 14 { fnList.append((c.family, c.messages.last ?? "")) }
        }
    } else {
        if enforced {
            fp += 1
            if fpList.count < 14 { fpList.append((c.family, c.messages.last ?? "")) }
        } else { tn += 1 }
    }
}

latencies.sort()
func p(_ q: Double) -> Double { latencies[min(latencies.count - 1, Int(Double(latencies.count - 1) * q))] }

let pos = tp + fn, neg = tn + fp
let recall = pos == 0 ? 0 : Double(tp) / Double(pos)
let precision = (tp + fp) == 0 ? 0 : Double(tp) / Double(tp + fp)
let fpr = neg == 0 ? 0 : Double(fp) / Double(neg)
let acc = Double(tp + tn) / Double(cases.count)

print(String(repeating: "=", count: 70))
print("TIERS 1+2 ONLY — same shuffled pool, no LLM")
print(String(repeating: "=", count: 70))
print("\(cases.count) cases: \(pos) attacks, \(neg) innocent")
print("deterministic canonicalisation + extraction + retrieval. No model call.\n")
print(String(format: "  recall     %6.1f%%   (%d of %d attacks caught)", recall * 100, tp, pos))
print(String(format: "  precision  %6.1f%%", precision * 100))
print(String(format: "  FPR        %6.1f%%   (%d of %d innocent messages flagged)", fpr * 100, fp, neg))
print(String(format: "  accuracy   %6.1f%%", acc * 100))
print(String(format: "  latency    p50 %.2f ms   p95 %.2f ms   p99 %.2f ms", p(0.50), p(0.95), p(0.99)))
print(String(format: "  total time %.2f s for all %d cases", latencies.reduce(0, +) / 1000, cases.count))
print("")
print("  would escalate to Tier 3: \(escalated) of \(cases.count) (\(String(format: "%.1f%%", Double(escalated) / Double(cases.count) * 100)))")
print("")

if fp > 0 {
    print("  FALSE POSITIVES (\(fp)):")
    for (fam, txt) in fpList { print("    [\(fam.prefix(22))] \(txt.prefix(62))") }
} else {
    print("  FALSE POSITIVES: none")
}
print("")
print("  MISSED ATTACKS (\(fnList.count) shown of \(fn)):")
for (fam, txt) in fnList { print("    [\(fam.prefix(22))] \(txt.prefix(62))") }
exit(0)
