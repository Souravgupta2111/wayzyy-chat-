// Harness: targeted behavioural probes for individual engine guarantees.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}

let engine = ModerationEngine.shared
var failures = 0

func fresh() -> ActorContext {
    ActorContext(trust: .standard, stage: .inquiry,
                 conversationID: "probe-\(UUID().uuidString)", senderID: "me")
}

func expectAllowed(_ section: String, _ cases: [String]) {
    print("=== \(section) ===")
    for text in cases {
        let v = engine.evaluate(text, actor: fresh(), useConversationBuffer: false)
        let ok = v.action == .allow || v.action == .hint
        if !ok { failures += 1 }
        print("  \(ok ? "PASS" : "FAIL") \(pad(v.action.rawValue, 6)) \(text)")
        if !ok {
            print("       shown: \(v.maskedText)")
            for d in v.detections {
                print("       det: \(d.category.rawValue) '\(d.canonical)' — \(d.reason)")
            }
        }
    }
    print("")
}

func expectCaught(_ section: String, _ cases: [String]) {
    print("=== \(section) ===")
    for text in cases {
        let v = engine.evaluate(text, actor: fresh(), useConversationBuffer: false)
        let caught = v.action != .allow && v.action != .hint
        if !caught { failures += 1 }
        print("  \(caught ? "PASS" : "MISS") \(pad(v.action.rawValue, 6)) \(text)")
    }
    print("")
}

expectAllowed("clock times and check-in prose", [
    "come at 10 pm for checkin",
    "come at 10 pm",
    "10 pm for checkin",
    "checkin at 10 am please",
    "breakfast at 8 am, dinner at 9 pm",
    "checkout is 11 am, gate opens 6 am",
    "see you at 9 am tomorrow",
    "we will reach by 7 pm",
])

expectAllowed("payments and names in Hindi", [
    "Abhishek ko 430 rupay dedena",
    "Abhishek ko 400 rupay dedena",
    "Priya ko 500 de dena",
    "Rohan ko 250 rupay bhej dena",
    "give Abhishek 400 rupees please",
    "Abhishek will meet you at the gate",
    "Akshay aur Abhishek dono aayenge",
])

expectAllowed("ordinary numeric prose", [
    "total came to 12,500 including the 1,200 cleaning fee",
    "total is 12,500 for 3 nights",
    "Total is 12,500 for 3 nights and 4 guests",
    "we are 4 adults and 2 kids",
    "the room is 12 by 14 feet, ceiling 10 feet",
    "Rated 4.8 out of 5 across 126 reviews",
    "our GSTIN is 27AAPFU0939F1ZV if you need it",
    "Booking reference WZ4471829 confirmed for 12/08/2026",
    "My flight AI 2109 lands at 14:35, checkout is at 11",
    "Invoice 8829 for 4 nights at 3200 per night, total 12800",
    "do teen din ke liye chahiye, char log aayenge",
    "chalis pachas hazaar ka budget hai humara",
    "das bees log aa sakte hain, jagah hai kya",
])

expectCaught("real contact cues still caught", [
    "pm me your number",
    "pm me akshay_goa_villa",
    "dm me on insta akshay_goa_villa",
    "my insta is akshay_villa_goa",
    "whatsapp me on 9876543210",
    "nien aight sevn six fyve for three too won zeero",
    "847 zero sattar assi 34",
    "78zerofive432670",
    "akshay at gmail dot com",
    "send the payment to akshay@ybl please",
    "reach me on akshay dot villa at gmail",
])

print("=== cross-message assembly, then innocent tail ===")
do {
    let actor = ActorContext(trust: .standard, stage: .inquiry,
                             conversationID: "assembly", senderID: "me")
    engine.resetBuffer(actor: actor)

    let script: [(String, Bool)] = [
        ("Hey my wp 983", false),
        ("Twenty five 4", false),
        ("3 2", false),
        ("430", true),
        ("come at 10 pm for checkin", false),
        ("Abhishek ko 430 rupay dedena", false),
        ("total is 12,500 for 3 nights", false),
        ("we are 4 adults and 2 kids", false),
        ("see you at 9 am tomorrow", false),
        ("breakfast at 8 am please", false),
    ]

    var assemblyFired = false
    for (text, mayMask) in script {
        let v = engine.evaluate(text, actor: actor, useConversationBuffer: true)
        let masked = v.action != .allow && v.action != .hint
        if masked, mayMask { assemblyFired = true }
        let bad = masked && !mayMask
        if bad { failures += 1 }
        print("  \(bad ? "FAIL " : "ok   ") \(pad(v.action.rawValue, 6)) \(text)")
        if masked { print("        shown: \(v.maskedText)") }
        if !v.action.withholdsMessage { engine.remember(text, actor: actor) }
    }
    if !assemblyFired {
        failures += 1
        print("  FAIL  assembly never fired — the chunked number was not caught")
    }
}
print("")

print("=== redaction lands on digits, not names ===")
do {
    let actor = ActorContext(trust: .standard, stage: .inquiry,
                             conversationID: "range", senderID: "me")
    engine.resetBuffer(actor: actor)
    for text in ["Hey my wp 983", "Twenty five 4", "3 2"] {
        let v = engine.evaluate(text, actor: actor, useConversationBuffer: true)
        if !v.action.withholdsMessage { engine.remember(text, actor: actor) }
        _ = v
    }
    let v = engine.evaluate("Abhishek 430", actor: actor, useConversationBuffer: true)
    let leaksName = v.maskedText.contains("●") && !v.maskedText.contains("Abhishek")
    if leaksName { failures += 1 }
    print("  \(leaksName ? "FAIL" : "PASS") shown: \(v.maskedText)")
    if v.action != .allow, !v.maskedText.contains("Abhishek") {
        print("        the name was redacted instead of the digits")
    }
}
print("")

print("=== prompt injection enforced without the model ===")
for c in RedTeamWave2.promptInjection {
    let actor = ActorContext(trust: .standard, stage: .inquiry,
                             conversationID: "inj-\(c.id)", senderID: "b")
    engine.resetBuffer(actor: actor)
    var last: Verdict!
    for m in c.messages {
        last = engine.evaluate(m, actor: actor, useConversationBuffer: true)
        if !last.action.withholdsMessage { engine.remember(m, actor: actor) }
    }
    let enforced = last.action != .allow && last.action != .hint
    if !enforced { failures += 1 }
    print("  \(enforced ? "PASS" : "FAIL") \(pad(last.action.rawValue, 6)) #\(c.id) \(c.technique)")
}
print("")

print(failures == 0 ? "ALL PROBES PASSED" : "\(failures) PROBE FAILURES")
exit(failures == 0 ? 0 : 1)
