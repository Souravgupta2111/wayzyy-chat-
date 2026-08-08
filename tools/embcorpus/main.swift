// Harness: scores the embedding backend over the corpus.

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

struct Result {
    var tp = 0, fn = 0, tn = 0, fp = 0
    var escalated = 0
    var latencies: [Double] = []
    var fpList: [String] = []

    var recall: Double { (tp + fn) == 0 ? 0 : Double(tp) / Double(tp + fn) }
    var precision: Double { (tp + fp) == 0 ? 0 : Double(tp) / Double(tp + fp) }
    var fpr: Double { (tn + fp) == 0 ? 0 : Double(fp) / Double(tn + fp) }
    var p50: Double {
        guard !latencies.isEmpty else { return 0 }
        let s = latencies.sorted(); return s[s.count / 2]
    }
}

func measure() -> Result {
    var r = Result()
    for c in cases {
        let actor = ActorContext(trust: .standard, stage: .inquiry,
                                 conversationID: "emb-\(c.id)", senderID: "s")
        engine.resetBuffer(actor: actor)
        var enforced = false, escalates = false, total = 0.0
        for m in c.messages {
            let v = engine.evaluate(m, actor: actor, useConversationBuffer: true)
            total += v.latencyMs
            if v.action != .allow && v.action != .hint { enforced = true }
            if engine.shouldEscalate(v) { escalates = true }
            if !v.action.withholdsMessage { engine.remember(m, actor: actor) }
        }
        r.latencies.append(total)
        if !enforced && escalates { r.escalated += 1 }
        if c.shouldFlag {
            if enforced { r.tp += 1 } else { r.fn += 1 }
        } else {
            if enforced {
                r.fp += 1
                if r.fpList.count < 8 { r.fpList.append(c.messages.last ?? "") }
            } else { r.tn += 1 }
        }
    }
    return r
}

func report(_ name: String, _ r: Result) {
    print("\n  \(name)")
    print(String(format: "    recall     %6.1f%%   (%d/%d)", r.recall * 100, r.tp, r.tp + r.fn))
    print(String(format: "    precision  %6.1f%%", r.precision * 100))
    print(String(format: "    FPR        %6.1f%%   (%d/%d innocent)", r.fpr * 100, r.fp, r.tn + r.fp))
    print(String(format: "    escalates  %6.1f%%   (%d cases -> Tier 3)",
                 Double(r.escalated) / Double(cases.count) * 100, r.escalated))
    print(String(format: "    p50        %6.2f ms", r.p50))
    if !r.fpList.isEmpty {
        print("    false positives:")
        for t in r.fpList { print("      \(t.prefix(58))") }
    }
}

print("=== TIER 2 VECTORISER COMPARISON — 480 mixed cases ===")

print("\nbaseline: lexical hashed n-gram (\(engine.retriever.backendIdentifier))")
let lexical = measure()

print("\nswitching to embeddings…")
let started = Date()
guard let embedded = SemanticRetriever.embeddingBacked() else {
    print("no embedding endpoint — skipping")
    report("LEXICAL", lexical)
    exit(0)
}
engine.retriever = embedded
print(String(format: "corpus embedded in %.1f s (one-off)", Date().timeIntervalSince(started)))
let emb = measure()

report("LEXICAL   (\(lexical.tp) caught)", lexical)
report("EMBEDDING (\(emb.tp) caught)", emb)

print("\n=== DELTA ===")
print(String(format: "  recall     %+.1f pts", (emb.recall - lexical.recall) * 100))
print(String(format: "  FPR        %+.1f pts", (emb.fpr - lexical.fpr) * 100))
print(String(format: "  escalation %+.1f pts  (cost driver)",
             (Double(emb.escalated) - Double(lexical.escalated)) / Double(cases.count) * 100))
print(String(format: "  p50        %+.2f ms  (per message, cached after first)",
             emb.p50 - lexical.p50))
exit(0)
