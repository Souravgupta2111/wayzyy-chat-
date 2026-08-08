// Harness: the headline regression metrics used by verify.sh.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

func pct(_ d: Double) -> String { String(format: "%.1f%%", d * 100) }
func pct2(_ d: Double) -> String { String(format: "%.2f%%", d * 100) }
func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}

print("=== WAVE 1 RED TEAM ===")
let rt = RedTeamSuite.run()
print("  cases:        \(rt.total)")
print("  caught:       \(rt.caught)")
print("  missed:       \(rt.missed)")
print("  catch rate:   \(pct(rt.catchRate))")
print(String(format: "  mean latency: %.2f ms", rt.meanLatency))
print("")
print("  per family:")
for family in RedTeamFamily.allCases {
    let subset = rt.byFamily(family)
    guard !subset.isEmpty else { continue }
    let caught = subset.filter(\.caught).count
    print("    \(pad(String(describing: family), 26)) \(caught)/\(subset.count)")
}
if !rt.misses.isEmpty {
    print("")
    print("  misses (\(rt.misses.count)):")
    for m in rt.misses {
        print("    #\(m.testCase.id) [\(m.testCase.family)] \((m.testCase.messages.first ?? "").prefix(64))")
    }
}
print("")

print("=== REGRESSION SUITE ===")
let sr = AdversarialSuite.run()
print("  cases:        \(sr.results.count)   positives \(sr.positives)  negatives \(sr.negatives)")
print("  recall:       \(pct(sr.recall))")
print("  precision:    \(pct(sr.precision))")
print("  accuracy:     \(pct(sr.accuracy))")
print("  FPR:          \(pct2(sr.falsePositiveRate))  (\(sr.falsePositives) of \(sr.negatives) innocent)")
print(String(format: "  p50/p95/p99:  %.2f / %.2f / %.2f ms", sr.p50, sr.p95, sr.p99))
if sr.falseNegatives > 0 {
    print("  missed positives:")
    for r in sr.results where r.testCase.shouldFlag && !r.flagged {
        print("    \(r.testCase.text.prefix(70))")
    }
}
if sr.falsePositives > 0 {
    print("  FALSE POSITIVES:")
    for r in sr.results where !r.testCase.shouldFlag && r.flagged {
        print("    \(r.testCase.text.prefix(70))")
    }
}
print("")

print("=== BASELINES ===")
let cmp = BaselineComparison.runLocal()
for o in cmp.outcomes {
    if let reason = o.unavailableReason {
        print("  \(pad(o.baseline.rawValue, 15)) unavailable — \(reason.prefix(60))")
        continue
    }
    print("  \(pad(o.baseline.rawValue, 15)) recall \(pad(pct(o.recall), 7)) FPR \(pad(pct2(o.falsePositiveRate), 7)) precision \(pad(pct(o.precision), 7))"
          + String(format: " p50 %.2f ms", o.p50))
}
print("")

print("=== LATENCY GUARD ===")
let engine = ModerationEngine.shared
let actor = ActorContext(trust: .standard, stage: .inquiry, conversationID: "bench", senderID: "me")
func bench(_ label: String, _ text: String) {
    let t = Date()
    let v = engine.evaluate(text, actor: actor, useConversationBuffer: false)
    let ms = Date().timeIntervalSince(t) * 1000
    print("  \(pad(label, 24)) chars \(pad(String(text.count), 7))" + String(format: " %.1f ms", ms) + "  → \(v.action.rawValue)")
}
bench("pathological digits", String(repeating: "9 8 7 6 5 4 3 2 1 0 whatsapp me on ", count: 400))
bench("wall of innocent text", String(repeating: "The villa has three bedrooms and a private pool. ", count: 600))
bench("homoglyph spam", String(repeating: "cаll mе оn nіnе еіght sеvеn ", count: 400))
print("")
exit(0)
