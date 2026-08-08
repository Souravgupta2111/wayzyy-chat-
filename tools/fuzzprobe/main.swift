// Harness: fuzzes innocent sentences looking for false positives.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

let vocabulary = """
email mail mails emails room rooms feet foot meat sheet sheets line lines time
times mine mines kid kids kind mango tango wine fine nine like life bike hike
hire fiber viper video type sign signs into info gate date late rate rates note
notes bed beds bath baths pool cool tool wifi water heater towel towels iron
kettle keys key car cars park parking villa house home flat block floor stairs
lift beach sand sea view city town road street lane market shop cafe food meal
meals dinner lunch breakfast tea coffee milk sugar salt fresh clean dirty broken
fixed repair leak light fan light ac heat cold warm quiet noisy safe secure
guest guests adult adults child children infant baby family couple group
booking bookings payment refund deposit invoice receipt total price cost
check checkin checkout arrive arrival depart leave stay nights days weeks
please thanks thank sorry sure yes okay fine good great lovely nice
""".split(whereSeparator: { $0.isWhitespace }).map(String.init)

var hits: [(String, String)] = []
for word in Set(vocabulary).sorted() {
    if let platform = Lex.fuzzyPlatform(word), platform != word {
        hits.append((word, platform))
    }
}

print("=== fuzzyPlatform collisions on ordinary vocabulary ===")
print("tested \(Set(vocabulary).count) words\n")
for (word, platform) in hits {
    print("  \(word.padding(toLength: 12, withPad: " ", startingAt: 0)) → \(platform)")
}
print("\n  \(hits.count) collisions")

print("\n=== sentences masked by a fuzzy platform match ===")
let engine = ModerationEngine.shared
let sentences = [
    "my email preferences are set already",
    "send it to my email address on file please",
    "the room is 12 by 14 feet with a queen bed",
    "there is a mango tree in the garden",
    "the line for the ferry was very long",
    "we have 2 kids and 1 infant",
    "what time is checkout",
    "the pool is 20 feet long",
    "is the wine included in the price",
    "that is fine, see you then",
    "please note the gate code is shared on arrival",
]
var masked = 0
for s in sentences {
    let actor = ActorContext(trust: .standard, stage: .inquiry,
                             conversationID: "fz-\(UUID().uuidString)", senderID: "me")
    let v = engine.evaluate(s, actor: actor, useConversationBuffer: false)
    let bad = v.action != .allow && v.action != .hint
    if bad {
        masked += 1
        print("  MASKED  \(s)")
        for d in v.detections { print("          \(d.category.rawValue) '\(d.canonical)' — \(d.reason)") }
    }
}
print("  \(masked) of \(sentences.count) ordinary sentences masked")
exit(0)
