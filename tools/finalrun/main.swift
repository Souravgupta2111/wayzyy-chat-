// Harness: end-to-end run reporting recall, precision and false positives.

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

let TIER3_MODEL = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "qwen2.5:7b"

struct Outcome {
    var name = ""
    var tp = 0, fn = 0, tn = 0, fp = 0
    var escalated = 0
    var modelCalls = 0
    var writeLatencies: [Double] = []
    var modelLatencies: [Double] = []
    var fpExamples: [String] = []
    var fnExamples: [String] = []

    var recall: Double { (tp + fn) == 0 ? 0 : Double(tp) / Double(tp + fn) }
    var precision: Double { (tp + fp) == 0 ? 0 : Double(tp) / Double(tp + fp) }
    var fpr: Double { (tn + fp) == 0 ? 0 : Double(fp) / Double(tn + fp) }
    var accuracy: Double { Double(tp + tn) / Double(max(1, tp + tn + fp + fn)) }

    func pct(_ q: Double, _ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * q))]
    }
    var writeP50: Double { pct(0.50, writeLatencies) }
    var writeP99: Double { pct(0.99, writeLatencies) }
    var modelP50: Double { pct(0.50, modelLatencies) }

    mutating func record(_ c: Case, enforced: Bool) {
        if c.shouldFlag {
            if enforced { tp += 1 } else {
                fn += 1
                if fnExamples.count < 10 { fnExamples.append("[\(c.family.prefix(18))] \(c.messages.last ?? "")") }
            }
        } else {
            if enforced {
                fp += 1
                if fpExamples.count < 10 { fpExamples.append("[\(c.family.prefix(18))] \(c.messages.last ?? "")") }
            } else { tn += 1 }
        }
    }
}

func runDeterministic(_ name: String, tier2: Bool) -> Outcome {
    engine.tier2Enabled = tier2
    var o = Outcome(); o.name = name
    for c in cases {
        let actor = ActorContext(trust: .standard, stage: .inquiry,
                                 conversationID: "fin-\(name)-\(c.id)", senderID: "s")
        engine.resetBuffer(actor: actor)
        var enforced = false, escalates = false, total = 0.0
        for m in c.messages {
            let v = engine.evaluate(m, actor: actor, useConversationBuffer: true)
            total += v.latencyMs
            if v.action != .allow && v.action != .hint { enforced = true }
            if engine.shouldEscalate(v) { escalates = true }
            if !v.action.withholdsMessage { engine.remember(m, actor: actor) }
        }
        o.writeLatencies.append(total)
        if !enforced && escalates { o.escalated += 1 }
        o.record(c, enforced: enforced)
    }
    return o
}

func report(_ o: Outcome, showExamples: Bool = false) {
    print("\n  \(o.name)")
    print(String(format: "    recall     %6.1f%%   (%d/%d)", o.recall * 100, o.tp, o.tp + o.fn))
    print(String(format: "    precision  %6.1f%%", o.precision * 100))
    print(String(format: "    FPR        %6.1f%%   (%d/%d innocent)", o.fpr * 100, o.fp, o.tn + o.fp))
    print(String(format: "    accuracy   %6.1f%%", o.accuracy * 100))
    if !o.writeLatencies.isEmpty {
        print(String(format: "    write p50  %6.2f ms   p99 %.2f ms", o.writeP50, o.writeP99))
    }
    if o.modelCalls > 0 {
        print(String(format: "    model      %d calls (%.1f%% of messages), p50 %.0f ms",
                     o.modelCalls, Double(o.modelCalls) / Double(cases.count) * 100, o.modelP50))
    }
    if o.escalated > 0 && o.modelCalls == 0 {
        print(String(format: "    would escalate %d (%.1f%%)",
                     o.escalated, Double(o.escalated) / Double(cases.count) * 100))
    }
    if showExamples {
        if !o.fpExamples.isEmpty {
            print("    false positives:")
            for e in o.fpExamples { print("      \(e.prefix(66))") }
        }
        if !o.fnExamples.isEmpty {
            print("    missed:")
            for e in o.fnExamples.prefix(6) { print("      \(e.prefix(66))") }
        }
    }
}

print(String(repeating: "=", count: 74))
print("FINAL — all tier configurations, \(cases.count) mixed cases")
print(String(repeating: "=", count: 74))
print("\(cases.filter(\.shouldFlag).count) attacks, \(cases.filter { !$0.shouldFlag }.count) innocent")
print("Tier 3: \(TIER3_MODEL) via local Ollama\n")

print("[1/5] Tier 1 only…")
let t1 = runDeterministic("1. TIER 1 ONLY", tier2: false)

print("[2/5] Tier 1+2 lexical…")
engine.retriever = SemanticRetriever()
let t12lex = runDeterministic("2. TIER 1+2  (lexical retrieval)", tier2: true)

print("[3/5] Tier 1+2 embeddings…")
var t12emb: Outcome? = nil
if let embedded = SemanticRetriever.embeddingBacked() {
    engine.retriever = embedded
    t12emb = runDeterministic("3. TIER 1+2  (embedding retrieval, calibrated)", tier2: true)
} else {
    print("      no embedding endpoint — skipping")
    engine.retriever = SemanticRetriever()
}

var judgeConfig = RemoteJudge.Configuration.ollama(model: TIER3_MODEL)
judgeConfig.timeout = 120
engine.judge = RemoteJudge(configuration: judgeConfig, allowModelFallback: false)

Task {

    print("[4/4] Full pipeline…")
    if let embedded = SemanticRetriever.embeddingBacked() { engine.retriever = embedded }
    engine.tier2Enabled = true

    var full = Outcome(); full.name = "4. TIER 1+2+3  (production pipeline)"
    for c in cases {
        let actor = ActorContext(trust: .standard, stage: .inquiry,
                                 conversationID: "full-\(c.id)", senderID: "s")
        engine.resetBuffer(actor: actor)

        var enforced = false, total = 0.0
        var suspicious: Verdict? = nil
        var suspiciousMessage = c.messages.last ?? ""
        for m in c.messages {
            let v = engine.evaluate(m, actor: actor, useConversationBuffer: true)
            total += v.latencyMs
            if v.action != .allow && v.action != .hint { enforced = true }
            if !enforced, engine.shouldEscalate(v),
               suspicious == nil || (!v.suspicions.isEmpty && suspicious!.suspicions.isEmpty) {
                suspicious = v; suspiciousMessage = m
            }
            if !v.action.withholdsMessage { engine.remember(m, actor: actor) }
        }
        full.writeLatencies.append(total)

        if !enforced, let v = suspicious {
            let request = engine.judgeRequest(for: v, message: suspiciousMessage, actor: actor)
            let started = Date()
            let j = await engine.judge.judge(request)
            full.modelLatencies.append(Date().timeIntervalSince(started) * 1000)
            full.modelCalls += 1
            let revised = engine.applyJudgement(j, to: v, message: suspiciousMessage, actor: actor)
            if revised.action != .allow && revised.action != .hint { enforced = true }
        }
        full.record(c, enforced: enforced)
    }

    print("\n" + String(repeating: "=", count: 74))
    print("RESULTS")
    print(String(repeating: "=", count: 74))
    report(t1)
    report(t12lex)
    if let e = t12emb { report(e) }
    report(full, showExamples: true)

    print("\n" + String(repeating: "=", count: 74))
    print("SUMMARY")
    print(String(repeating: "=", count: 74))
    print("  configuration                    recall  precis     FPR   write p50   model")
    func row(_ o: Outcome) {
        print(String(format: "  %-31s %5.1f%%  %5.1f%%  %5.2f%%   %7.2f ms  %5d",
                     (o.name.replacingOccurrences(of: "  (", of2: " (") as NSString).utf8String!,
                     o.recall * 100, o.precision * 100, o.fpr * 100, o.writeP50, o.modelCalls))
    }
    row(t1); row(t12lex); if let e = t12emb { row(e) }; row(full)

    let rate = Double(full.modelCalls) / Double(cases.count)
    let hostedPerCall = 0.000075
    print("\n" + String(repeating: "=", count: 74))
    print("COST PER 100K MESSAGES")
    print(String(repeating: "=", count: 74))
    print(String(format: "  full pipeline escalation rate    %.1f%%", rate * 100))
    print(String(format: "  Tier 1+2 compute                 $0.01   (8 ms x 100k, 2 vCPU)"))
    print(String(format: "  Tier 3 self-hosted 8B            $0.00   marginal; $35-70/mo fixed"))
    print(String(format: "  Tier 3 hosted equivalent         $%.2f   (%.0f calls x $%.6f)",
                 100_000 * rate * hostedPerCall, 100_000 * rate, hostedPerCall))
    print(String(format: "  TOTAL, hosted Tier 3             $%.2f", 100_000 * rate * hostedPerCall + 0.01))
    print(String(format: "  LLM-on-every-message, hosted     $%.2f   (%.0fx more)",
                 100_000 * hostedPerCall, (100_000 * hostedPerCall) / (100_000 * rate * hostedPerCall + 0.01)))
    exit(0)
}

extension String {
    func replacingOccurrences(of a: String, of2 b: String) -> String {
        replacingOccurrences(of: a, with: b)
    }
}

dispatchMain()
