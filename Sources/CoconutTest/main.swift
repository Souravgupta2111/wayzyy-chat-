import Foundation
import WayzyyModeration

struct TestCase: Codable {
    struct Turn: Codable {
        let speaker: String
        let text: String
    }
    let id: String
    let category: String
    let turns: [Turn]
}

func points(for id: String) -> Int {
    if id.hasPrefix("CL") { return 10 }
    if id.hasPrefix("CE") { return 15 }
    if id.hasPrefix("LM") { return 20 }
    if id.hasPrefix("CO") { return 25 }
    if id.hasPrefix("MS") { return 30 }
    return 0
}

func expectFlag(_ id: String) -> Bool {
    if id.hasPrefix("CE") { return true }
    if id.hasPrefix("LM") { return ["LM-07", "LM-08", "LM-12"].contains(id) }
    if id.hasPrefix("CO") { return !["CO-11", "CO-12"].contains(id) }
    if id.hasPrefix("MS") { return !["MS-06", "MS-08", "MS-10"].contains(id) }
    return false
}

func isFlag(_ action: String?) -> Bool {
    switch action {
    case "mask", "warn", "block", "review": return true
    default: return false
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let testsURL = root.appendingPathComponent("tests2.json")
if !FileManager.default.fileExists(atPath: testsURL.path) {
    fputs("missing tests2.json in \(root.path)\n", stderr)
    exit(66)
}
let cases = try JSONDecoder().decode([TestCase].self, from: Data(contentsOf: testsURL))

var env = ProcessInfo.processInfo.environment
if env["WAYZYY_SECRETS_FILE"] == nil {
    setenv("WAYZYY_SECRETS_FILE", root.appendingPathComponent("Secrets.json").path, 1)
}
if env["WAYZYY_TIER3"] == nil {
    setenv("WAYZYY_TIER3", "pooled", 1)
}

let report: BootstrapReport
do {
    report = try WayzyyModerationService.bootstrap()
} catch {
    fputs("bootstrap failed: \(error)\n", stderr)
    exit(78)
}

print("bootstrap adjudicator=\(report.adjudicator) tier3=\(report.tier3Available) policy=\(report.policyVersion)")
for note in report.notes { print("  note: \(note)") }
print("cases: \(cases.count)\n")

var score = 0
var maxScore = 0
var hits = 0
var misses: [(id: String, expect: Bool, action: String, reasons: String, t3: String)] = []
var byCat: [String: (ok: Int, n: Int, pts: Int, max: Int)] = [:]

for tc in cases {
    let pts = points(for: tc.id)
    maxScore += pts
    let want = expectFlag(tc.id)
    var flagged = false
    var lastAction = "allow"
    var lastReasons: [String] = []
    var t3Note = "-"

    for (i, turn) in tc.turns.enumerated() {
        var req = ModerationRequestDTO(
            id: "\(tc.id)-t\(i)-\(UUID().uuidString)",
            text: turn.text,
            conversationID: tc.id,
            senderID: turn.speaker
        )
        let verdict = try WayzyyModerationService.handleDurably(req)
        lastAction = verdict.action ?? "allow"
        lastReasons = verdict.reasonCodes ?? []
        if verdict.escalationCandidate == true {
            _ = WayzyyModerationService.drainAdjudications(timeout: 25)
            if let adj = WayzyyModerationService.adjudication(forRequestID: req.id ?? "") {
                t3Note = "\(adj.action ?? "?")"
                lastAction = adj.action ?? lastAction
                lastReasons = adj.reasonCodes ?? lastReasons
            } else {
                t3Note = "escalated-no-revision"
            }
        }
        if isFlag(lastAction) { flagged = true }
    }

    let ok = flagged == want
    var row = byCat[tc.category] ?? (0, 0, 0, 0)
    row.n += 1
    row.max += pts
    if ok {
        hits += 1
        score += pts
        row.ok += 1
        row.pts += pts
    } else {
        misses.append((tc.id, want, lastAction, lastReasons.joined(separator: ","), t3Note))
    }
    byCat[tc.category] = row
    let mark = ok ? "OK" : "MISS"
    print("\(mark) \(tc.id) wantFlag=\(want) got=\(lastAction) t3=\(t3Note) pts=\(ok ? pts : 0)/\(pts)")
    fflush(stdout)
}

print("\n======== ROUND 2 RESULTS ========")
print("engine: \(report.adjudicator)  tier3: \(report.tier3Available)  policy: \(report.policyVersion)")
print("cases: \(hits)/\(cases.count) correct")
print("score: \(score)/\(maxScore)  (\(String(format: "%.1f", 100 * Double(score) / Double(max(maxScore, 1))))%)")
print("\nby category:")
for key in ["clean_control", "contact_evasion", "language_mix", "coercion", "multiturn_split"] {
    guard let r = byCat[key] else { continue }
    print("  \(key): \(r.ok)/\(r.n) cases, \(r.pts)/\(r.max) pts")
}
print("\nmisses (\(misses.count)):")
if misses.isEmpty {
    print("  none")
} else {
    for m in misses {
        print("  \(m.id) expectedFlag=\(m.expect) got=\(m.action) t3=\(m.t3) reasons=\(m.reasons)")
    }
}
