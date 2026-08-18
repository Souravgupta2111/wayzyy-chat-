// Harness: per-case ledger. One row per test case with tier, action, latency and cost.
// Emits TSV so it can be pasted or parsed without further processing.

import Foundation

// Cost model:
//   CPU:   single-core throughput 298 msg/s ordinary traffic -> derive $/core-second
//   Tier3: 719 measured tokens/call (649 in + 70 out) on a hosted small model.
//          Llama 3.1 8B @ $0.02/M in, $0.05/M out:
//            649 * 0.02/1e6 + 70 * 0.05/1e6 = $0.00001648
let dollarsPerCoreHour = 0.02
let dollarsPerCoreSecond = dollarsPerCoreHour / 3600.0
let tier3CallCost = 0.0000165

struct Row {
    let id: Int
    let suite: String
    let family: String
    let expected: String
    let messageCount: Int
    let text: String
    let tier: Int
    let action: String
    let latencyMs: Double
    let escalated: Bool
    let categories: String
    let suspicions: String
    let reasons: String
    var cpuCost: Double { latencyMs / 1000.0 * dollarsPerCoreSecond }
    var modelCost: Double { escalated ? tier3CallCost : 0 }
    var totalCost: Double { cpuCost + modelCost }
    var correct: Bool {
        let flagged = action != "allow"
        return expected == "attack" ? (flagged || escalated) : !flagged
    }
}

let engine = ModerationEngine.shared
engine.tier2Enabled = true

var rows: [Row] = []
var id = 0

/// Evaluate one CASE. A case may be a single message or a multi-message sequence in
/// which no individual message is a violation and the payload only exists across the
/// whole conversation (acrostics, split digit runs). Sequences therefore run through
/// one shared conversation with the buffer live — production semantics — and the case
/// verdict is the strongest action reached anywhere in the sequence.
func runCase(suite: String, family: String, expected: String, messages: [String]) {
    id += 1
    let actor = ActorContext(trust: .standard, stage: .inquiry,
                             conversationID: "pc-\(id)", senderID: "s-\(id)")
    engine.resetBuffer(actor: actor)

    let sequence = messages.count > 1
    var best: Verdict? = nil
    var totalLatency = 0.0
    var escalated = false
    var cats = Set<String>()
    var susp = Set<String>()
    var reasons: [String] = []

    for m in messages {
        let v = engine.evaluate(m, actor: actor, useConversationBuffer: sequence)
        totalLatency += v.latencyMs
        if engine.shouldEscalate(v) { escalated = true }
        cats.formUnion(v.categories.map(\.rawValue))
        susp.formUnion(v.suspicions.map { "\($0)" })
        for r in v.reasonCodes where !reasons.contains(r) { reasons.append(r) }
        if best == nil || v.action.rank > best!.action.rank { best = v }
        // Mirror production: delivered messages join the conversation buffer, which is
        // what makes cross-message assembly detectable at all.
        if sequence, !v.action.withholdsMessage { engine.remember(m, actor: actor) }
    }
    guard let v = best else { return }

    let shown = messages.count == 1
        ? messages[0]
        : messages.map { "\u{2022} " + $0 }.joined(separator: "  ")

    rows.append(Row(
        id: id,
        suite: suite,
        family: family,
        expected: expected,
        messageCount: messages.count,
        text: shown.replacingOccurrences(of: "\t", with: " ")
                   .replacingOccurrences(of: "\n", with: " "),
        tier: v.tierReached,
        action: v.action.rawValue,
        latencyMs: totalLatency,
        escalated: escalated,
        categories: cats.sorted().joined(separator: "|"),
        suspicions: susp.sorted().joined(separator: "|"),
        reasons: reasons.joined(separator: "|")
    ))
}

if let official = try? String(contentsOfFile: "tools/wayzyy_cases.txt", encoding: .utf8) {
    for line in official.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        runCase(suite: "official", family: "wayzyy10", expected: "attack", messages: [String(line)])
    }
}
for c in AdversarialSuite.allCases {
    runCase(suite: "regression", family: c.shouldFlag ? "positive" : "innocent",
            expected: c.shouldFlag ? "attack" : "innocent", messages: [c.text])
}
for c in RedTeamCorpus.all {
    runCase(suite: "wave1", family: "\(c.family)", expected: "attack", messages: c.messages)
}
for c in RedTeamWave2.all {
    runCase(suite: "wave2", family: "\(c.family)",
            expected: c.shouldFlag ? "attack" : "innocent", messages: c.messages)
}

// ---- TSV ledger ----
// Layer attribution derived from reason codes.
func layer(_ r: Row) -> String {
    var l: [String] = []
    if r.reasons.contains("SYSTEM_MANIPULATION") { l.append("L5-injection") }
    if r.reasons.contains("SAFETY_") { l.append("T1-safety") }
    if r.categories.contains("phone") || r.categories.contains("email")
        || r.categories.contains("socialHandle") || r.categories.contains("externalURL")
        || r.categories.contains("paymentHandle") || r.categories.contains("bankDetails")
        || r.categories.contains("cryptoAddress") { l.append("T1-contact") }
    if r.tier == 2 || r.reasons.contains("TIER2") { l.append("T2-retrieval") }
    if r.reasons.contains("LAYER3_ROUTE") { l.append("L3-classifier") }
    if r.reasons.contains("BEHAVIOUR_PATTERN") { l.append("L6-actor") }
    if r.reasons.contains("SUSPICION") { l.append("L5-router") }
    if r.escalated { l.append("→T3") }
    if l.isEmpty { l.append(r.action == "allow" ? "T1-clean" : "T1") }
    return l.joined(separator: "+")
}

print("id\tsuite\tfamily\texpected\tmsgs\tlayer\ttier\taction\tescalated\tlatency_ms\tcpu_usd\tmodel_usd\ttotal_usd\tcorrect\tcategories\tsuspicions\treasons\ttext")
for r in rows {
    print("\(r.id)\t\(r.suite)\t\(r.family)\t\(r.expected)\t\(r.messageCount)\t\(layer(r))\t\(r.tier)\t\(r.action)\t\(r.escalated ? 1 : 0)\t"
        + String(format: "%.3f\t%.10f\t%.8f\t%.8f\t", r.latencyMs, r.cpuCost, r.modelCost, r.totalCost)
        + "\(r.correct ? 1 : 0)\t\(r.categories)\t\(r.suspicions)\t\(r.reasons)\t\(r.text)")
}

print("\n=== LAYER ATTRIBUTION ===")
print("layer\tcases\tshare")
let byLayer = Dictionary(grouping: rows, by: { layer($0) })
for (k, g) in byLayer.sorted(by: { $0.value.count > $1.value.count }) {
    print("\(k)\t\(g.count)\t\(pct(g.count, rows.count))")
}

// ---- Rollups ----
func pct(_ a: Int, _ b: Int) -> String {
    b == 0 ? "-" : String(format: "%.1f%%", 100.0 * Double(a) / Double(b))
}
func percentile(_ s: [Double], _ p: Double) -> Double {
    guard !s.isEmpty else { return 0 }
    return s[max(0, min(Int((Double(s.count - 1) * p).rounded()), s.count - 1))]
}

print("\n=== ROLLUP BY SUITE ===")
print("suite\tcases\ttier1\ttier2\ttier3_routed\tenforced\tcorrect\tp50_ms\tp95_ms\ttotal_usd")
for suite in ["official", "regression", "wave1", "wave2"] {
    let g = rows.filter { $0.suite == suite }
    guard !g.isEmpty else { continue }
    let lat = g.map(\.latencyMs).sorted()
    print("\(suite)\t\(g.count)\t\(g.filter { $0.tier <= 1 }.count)\t\(g.filter { $0.tier == 2 }.count)"
        + "\t\(g.filter(\.escalated).count)\t\(g.filter { $0.action != "allow" }.count)"
        + "\t\(pct(g.filter(\.correct).count, g.count))"
        + String(format: "\t%.2f\t%.2f\t%.6f", percentile(lat, 0.50), percentile(lat, 0.95),
                 g.reduce(0) { $0 + $1.totalCost }))
}

print("\n=== ROLLUP BY ACTION ===")
print("action\tcases\tshare\tmean_ms")
let byAction = Dictionary(grouping: rows, by: \.action)
for (a, g) in byAction.sorted(by: { $0.value.count > $1.value.count }) {
    print("\(a)\t\(g.count)\t\(pct(g.count, rows.count))"
        + String(format: "\t%.2f", g.map(\.latencyMs).reduce(0, +) / Double(g.count)))
}

print("\n=== ROLLUP BY FAMILY ===")
print("suite\tfamily\tcases\tcaught_or_routed\tenforced_t1t2\trouted\tmiss\tp50_ms\tusd")
let byFam = Dictionary(grouping: rows, by: { "\($0.suite)\t\($0.family)" })
for (k, g) in byFam.sorted(by: { $0.key < $1.key }) {
    let lat = g.map(\.latencyMs).sorted()
    let miss = g.filter { !$0.correct }.count
    print("\(k)\t\(g.count)\t\(g.filter(\.correct).count)\t\(g.filter { $0.action != "allow" }.count)"
        + "\t\(g.filter(\.escalated).count)\t\(miss)"
        + String(format: "\t%.2f\t%.6f", percentile(lat, 0.50), g.reduce(0) { $0 + $1.totalCost }))
}

print("\n=== MISSES (expected attack, allowed and not routed) ===")
for r in rows where r.expected == "attack" && !r.correct {
    print("#\(r.id)\t\(r.suite)/\(r.family)\t\(r.action)\t\(r.text)")
}

print("\n=== FALSE POSITIVES (innocent, enforced) ===")
let fps = rows.filter { $0.expected == "innocent" && $0.action != "allow" }
if fps.isEmpty { print("none") }
for r in fps { print("#\(r.id)\t\(r.suite)/\(r.family)\t\(r.action)\t\(r.text)") }

print("\n=== INNOCENTS THAT COST A TIER 3 CALL ===")
for r in rows where r.expected == "innocent" && r.escalated {
    print("#\(r.id)\t\(r.suite)\t\(r.suspicions)\t\(r.text)")
}

print("\n=== TOTALS ===")
let lat = rows.map(\.latencyMs).sorted()
print("cases=\(rows.count)")
print("attacks=\(rows.filter { $0.expected == "attack" }.count)  innocents=\(rows.filter { $0.expected == "innocent" }.count)")
print("tier1_only=\(rows.filter { $0.tier <= 1 }.count) tier2=\(rows.filter { $0.tier == 2 }.count) tier3_routed=\(rows.filter(\.escalated).count)")
print(String(format: "latency p50=%.3f p95=%.3f p99=%.3f max=%.3f",
             percentile(lat, 0.50), percentile(lat, 0.95), percentile(lat, 0.99), lat.last ?? 0))
print(String(format: "cpu_usd=%.8f model_usd=%.6f total_usd=%.6f",
             rows.reduce(0) { $0 + $1.cpuCost },
             rows.reduce(0) { $0 + $1.modelCost },
             rows.reduce(0) { $0 + $1.totalCost }))
print(String(format: "usd_per_100k_extrapolated=%.4f",
             rows.reduce(0) { $0 + $1.totalCost } / Double(rows.count) * 100_000))
