// Harness: prints the full verdict for one or more messages.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

let engine = ModerationEngine.shared
let retriever = SemanticRetriever()

var args = Array(CommandLine.arguments.dropFirst())

var sequential = false
if args.first == "--seq" {
    sequential = true
    args.removeFirst()
}

let inputs: [String] = args.isEmpty
    ? [
        "mera number ek do teen chaar paanch chhe saat aath nau ek hai",
        "we will reach by 7 pm",
        "see you at 9 am tomorrow",
      ]
    : args

let sharedActor = ActorContext(trust: .standard, stage: .inquiry,
                               conversationID: "diag-seq", senderID: "me")
if sequential { engine.resetBuffer(actor: sharedActor) }

for text in inputs {
    let views = Canonicalizer().build(text)
    let ctx = NumericContext.analyze(views.base)
    let actor = sequential
        ? sharedActor
        : ActorContext(trust: .standard, stage: .inquiry,
                       conversationID: "diag-\(UUID().uuidString)", senderID: "me")
    let v = engine.evaluate(text, actor: actor, useConversationBuffer: sequential)

    print("──────────────────────────────────────────────")
    print("input        : \(text)")
    print("action       : \(v.action.rawValue)   score \(String(format: "%.3f", v.score))   threshold \(String(format: "%.3f", v.threshold))")
    print("base         : \(views.base.text)")
    print("digits       : '\(views.digits.text)'  (\(views.digits.text.count))")
    print("digitsMasked : '\(views.digitsMasked.text)'  (\(views.digitsMasked.text.count))")
    print("compactDigits: '\(views.compactDigits.text)'  (\(views.compactDigits.text.count))")
    print("separators   : \(views.separators.text)")
    print("numctx       : \(ctx.firedRules)")
    print("validates    : digits=\(Extractors.isHighConfidencePhone(views.digits.text)) masked=\(Extractors.isHighConfidencePhone(views.digitsMasked.text)) compact=\(Extractors.isHighConfidencePhone(views.compactDigits.text))")
    if let r = retriever.retrieve(text) {
        print("retrieval    : \(r.intent) sim \(String(format: "%.3f", r.similarity)) neg \(String(format: "%.3f", r.negativeSimilarity)) margin \(String(format: "%.3f", r.margin))")
        print("               nearest: \"\(r.nearestExemplar)\"")
    } else {
        print("retrieval    : none")
    }
    print("reasons      : \(v.reasonCodes)")
    print("suspicions   : \(v.suspicions.map(\.rawValue))")
    for c in v.carriers { print("carrier      : \(c.summary)") }
    if v.detections.isEmpty {
        print("detections   : none")
    } else {
        for d in v.detections {
            let chars = Array(text)
            let lo = max(0, min(d.range.lowerBound, chars.count))
            let hi = max(lo, min(d.range.upperBound, chars.count))
            print("detection    : \(d.category.rawValue) '\(d.canonical)' conf \(String(format: "%.2f", d.confidence))")
            print("               covers '\(String(chars[lo..<hi]))'  transforms \(d.transforms)")
            print("               \(d.reason)")
        }
    }
    print("shown        : \(v.maskedText)")
    print("")

    if sequential, !v.action.withholdsMessage {
        engine.remember(text, actor: actor)
    }
}
exit(0)
