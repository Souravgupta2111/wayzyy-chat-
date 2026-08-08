// Harness: times each stage of the write path.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

let short = "hey is the villa free next weekend for 4 guests"
let mid = String(repeating: "the villa has three bedrooms and a private pool. ", count: 4)
let long = String(repeating: "the villa has three bedrooms and a private pool overlooking the paddy fields. ", count: 8)
let huge = String(repeating: "the villa has three bedrooms and a private pool overlooking the paddy fields. ", count: 40)

func bench(_ label: String, _ iterations: Int, _ body: () -> Void) {
    for _ in 0..<3 { body() }
    let t = Date()
    for _ in 0..<iterations { body() }
    let ms = Date().timeIntervalSince(t) * 1000 / Double(iterations)
    print(String(format: "  %-40s %8.3f ms", (label as NSString).utf8String!, ms))
}

let engine = ModerationEngine.shared
let canon = Canonicalizer()
let retriever = SemanticRetriever()

for (name, text) in [("SHORT", short), ("MID", mid), ("LONG", long), ("HUGE", huge)] {
    print("\n=== \(name) — \(text.count) chars ===")

    bench("Canonicalizer.build (13 views)", 40) { _ = canon.build(text) }

    let views = canon.build(text)
    bench("NumericContext.analyze", 40) { _ = NumericContext.analyze(views.base) }
    bench("SemanticRetriever.retrieve", 40) { _ = retriever.retrieve(text) }

    let actor = ActorContext(trust: .standard, stage: .inquiry,
                            conversationID: "prof-\(name)", senderID: "s")
    engine.resetBuffer(actor: actor)
    bench("evaluate — buffer empty", 25) {
        _ = engine.evaluate(text, actor: actor, useConversationBuffer: true)
    }

    for m in ["my whatsapp is", "nine eight seven", "six five four", "three two one"] {
        _ = engine.evaluate(m, actor: actor, useConversationBuffer: true)
        engine.remember(m, actor: actor)
    }
    bench("evaluate — buffer live (production)", 25) {
        _ = engine.evaluate(text, actor: actor, useConversationBuffer: true)
    }
}

print("""

`allowExpensiveTiers` is false above 600 chars and buffer assembly is skipped above
1200, so LONG and HUGE already take the reduced path. Anything still slow there runs
unconditionally.
""")
exit(0)
