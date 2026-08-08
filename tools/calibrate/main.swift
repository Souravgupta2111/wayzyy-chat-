// Harness: sweeps retrieval similarity and margin thresholds against the corpus.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

struct Case: Decodable {
    let id: String
    let messages: [String]
    let shouldFlag: Bool
}

let data = try Data(contentsOf: URL(fileURLWithPath: "/tmp/corpus.json"))
let cases = try JSONDecoder().decode([Case].self, from: data)
let engine = ModerationEngine.shared

struct Outcome {
    var tp = 0, fn = 0, tn = 0, fp = 0, escalated = 0
    var recall: Double { (tp + fn) == 0 ? 0 : Double(tp) / Double(tp + fn) }
    var fpr: Double { (tn + fp) == 0 ? 0 : Double(fp) / Double(tn + fp) }
    var escalationRate: Double { Double(escalated) / Double(max(cases.count, 1)) }
}

func evaluateCorpus() -> Outcome {
    var o = Outcome()
    for c in cases {
        let actor = ActorContext(trust: .standard, stage: .inquiry,
                                 conversationID: "cal-\(c.id)", senderID: "s")
        engine.resetBuffer(actor: actor)
        var enforced = false, escalates = false
        for m in c.messages {
            let v = engine.evaluate(m, actor: actor, useConversationBuffer: true)
            if v.action != .allow && v.action != .hint { enforced = true }
            if engine.shouldEscalate(v) { escalates = true }
            if !v.action.withholdsMessage { engine.remember(m, actor: actor) }
        }
        if !enforced && escalates { o.escalated += 1 }
        if c.shouldFlag { enforced ? (o.tp += 1) : (o.fn += 1) }
        else { enforced ? (o.fp += 1) : (o.tn += 1) }
    }
    return o
}

func calibrate(name: String, makeRetriever: (SemanticRetriever.Thresholds) -> SemanticRetriever,
               similarities: [Double], margins: [Double],
               escSimilarities: [Double], escMargins: [Double]) {

    print("\n" + String(repeating: "=", count: 74))
    print("CALIBRATING: \(name)")
    print(String(repeating: "=", count: 74))

    print("\nENFORCEMENT sweep (Tier 2 may act). FPR must stay 0.")
    print("  sim    margin   recall     FPR    verdict")
    var best: (sim: Double, margin: Double, recall: Double)? = nil

    for sim in similarities {
        for margin in margins {
            engine.retriever = makeRetriever(
                SemanticRetriever.Thresholds(similarity: sim, margin: margin)
            )
            let o = evaluateCorpus()
            let usable = o.fpr == 0
            if usable, best == nil || o.recall > best!.recall {
                best = (sim, margin, o.recall)
            }
            if usable || o.fpr > 0 {
                print(String(format: "  %.2f    %.2f    %5.1f%%   %5.2f%%   %@",
                             sim, margin, o.recall * 100, o.fpr * 100,
                             (usable ? "ok" : "FP — rejected") as NSString))
            }
        }
    }

    guard let chosen = best else {
        print("  no threshold pair achieves zero false positives")
        return
    }
    print(String(format: "\n  → enforcement: similarity %.2f, margin %.2f (recall %.1f%%)",
                 chosen.sim, chosen.margin, chosen.recall * 100))

    engine.retriever = makeRetriever(
        SemanticRetriever.Thresholds(similarity: chosen.sim, margin: chosen.margin)
    )

    print("\nESCALATION sweep (what Tier 3 gets asked). Lower rate = lower bill.")
    print("  sim    margin   escalation   recall     FPR")
    var bestEsc: (sim: Double, margin: Double, rate: Double)? = nil

    for sim in escSimilarities {
        for margin in escMargins {
            EscalationAnalyser.escalationSimilarity = sim
            EscalationAnalyser.escalationMargin = margin
            let o = evaluateCorpus()
            guard o.fpr == 0 else { continue }
            if o.escalationRate >= 0.04,
               bestEsc == nil || o.escalationRate < bestEsc!.rate {
                bestEsc = (sim, margin, o.escalationRate)
            }
            print(String(format: "  %.2f    %.2f    %6.1f%%      %5.1f%%   %5.2f%%",
                         sim, margin, o.escalationRate * 100, o.recall * 100, o.fpr * 100))
        }
    }
    if let e = bestEsc {
        print(String(format: "\n  → escalation: similarity %.2f, margin %.2f (%.1f%% of traffic)",
                     e.sim, e.margin, e.rate * 100))
    }
}

let corpus = IntentExemplars.all.map(\.text) + IntentExemplars.negatives

let lexicalVectoriser = LexicalVectoriser(corpus: corpus)
calibrate(
    name: "lexical-hashed-ngram-v1  (current default)",
    makeRetriever: { SemanticRetriever(vectoriser: lexicalVectoriser, thresholds: $0) },
    similarities: [0.24, 0.28, 0.32],
    margins: [0.04, 0.06, 0.10],
    escSimilarities: [0.20, 0.24, 0.28],
    escMargins: [0.05, 0.08]
)

print("\nembedding the exemplar corpus…")
let embVectoriser = EmbeddingVectoriser(configuration: .ollama(), corpus: corpus)
if embVectoriser.probe() {
    calibrate(
        name: "embedding-nomic-embed-text",
        makeRetriever: { SemanticRetriever(vectoriser: embVectoriser, thresholds: $0) },
        similarities: [0.60, 0.68, 0.74, 0.80],
        margins: [0.05, 0.10, 0.15, 0.20],
        escSimilarities: [0.55, 0.62, 0.68],
        escMargins: [0.02, 0.05, 0.08]
    )
} else {
    print("no embedding endpoint reachable — skipped")
}
exit(0)
