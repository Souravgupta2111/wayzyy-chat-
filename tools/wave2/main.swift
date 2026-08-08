// Harness: runs the second adversarial wave.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}
func pct(_ d: Double) -> String { String(format: "%5.1f%%", d * 100) }

let r = RedTeamWave2Suite.run()

print("=== RED TEAM WAVE 2 ===")
print("attacks:            \(r.attacks.count)")
print("innocents:          \(r.innocents.count)")
print("caught by T1+T2:    \(r.caught)/\(r.attacks.count)  (\(pct(r.tier12Recall)))")
print("escalated to T3:    \(r.escalated)")
print("silent misses:      \(r.silentMisses.count)")
print("coverage ceiling:   \(pct(r.coverageCeiling))")
print("false positives:    \(r.falsePositives.count)/\(r.innocents.count)  (\(pct(r.falsePositiveRate)))")
print("innocent API calls: \(r.innocentCallsCost)/\(r.innocents.count)")
print(String(format: "mean latency:       %.2f ms", r.meanLatency))
print("")

print("=== PER FAMILY ===")
for f in Wave2Family.allCases {
    let s = r.byFamily(f)
    guard !s.isEmpty else { continue }
    if f == .innocent {
        print("\(pad(f.rawValue, 26)) \(s.count) cases · \(s.filter(\.caughtByTier12).count) false positives · \(s.filter(\.costsCall).count) escalated")
    } else {
        print("\(pad(f.rawValue, 26)) caught \(pad("\(s.filter(\.caughtByTier12).count)/\(s.count)", 8)) escalated \(pad(String(s.filter(\.escalated).count), 3)) silent \(s.filter(\.silentMiss).count)")
    }
}
print("")

print("=== SILENT MISSES ===")
if r.silentMisses.isEmpty { print("  none") }
for m in r.silentMisses {
    print("  #\(m.testCase.id) \(pad(m.testCase.technique, 34)) gate: \(m.testCase.targets)")
}
print("")

if !r.falsePositives.isEmpty {
    print("=== FALSE POSITIVES (must be zero) ===")
    for f in r.falsePositives {
        print("  #\(f.testCase.id) \(f.testCase.technique)")
        for msg in f.testCase.messages { print("      > \(msg.prefix(84))") }
        for v in f.verdicts where v.action != .allow && v.action != .hint {
            print("      \(v.action.rawValue): \(v.detections.map { "\($0.category.rawValue)=\($0.canonical)" }.joined(separator: ", "))")
        }
    }
    print("")
}

print("=== INNOCENTS THAT COST AN API CALL ===")
for c in r.innocents.filter(\.costsCall) {
    print("  #\(c.testCase.id) [\(c.suspicions.map(\.rawValue).joined(separator: ","))] \((c.testCase.messages.first ?? "").prefix(70))")
}
exit(0)
