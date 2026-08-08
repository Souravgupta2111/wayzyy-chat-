// Harness: computes the recall-versus-escalation-cost curve.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

let engine = ModerationEngine.shared

func pct(_ d: Double) -> String { String(format: "%5.1f%%", d * 100) }

let ordinary = [
    "hi, is the villa available next weekend",
    "hello! yes it is, for how many guests",
    "we are 4 adults and 2 kids",
    "that works, the villa sleeps 8",
    "what time is check in",
    "check in is 2 pm and check out 11 am",
    "is early check in possible, our train arrives at 6 am",
    "great, thank you so much",
    "is there parking",
    "yes, space for 2 cars inside the gate",
    "how far is the beach",
    "about 2.5 km, 8 minutes by scooter",
    "breakfast is 250 per person, dinner around 600 for 2",
    "total came to 12,500 including the 1,200 cleaning fee",
    "we will reach by 7 pm",
    "someone will be at the gate",
    "the wifi is not working in the second bedroom",
    "wifi details are in the house manual on the counter",
    "can we get 2 extra towels",
    "is late checkout possible on sunday",
    "Abhishek ko 430 rupay dedena for the taxi",
    "do teen din ke liye chahiye, char log aayenge",
    "hum saat baje pahunchenge, teen ghante lagenge",
    "bahut dhanyavaad, teen raat ka payment ho gaya hai",
    "thank you so much we had a wonderful time",
    "does this app send me a reminder before check in",
    "my email preferences are set already",
    "the gate code will be shared on the morning of arrival",
    "Villa Serena, Assagao, Bardez, North Goa, India, 403507",
    "our GSTIN is 27AAPFU0939F1ZV if you need it for the bill",
    "invoice 8829 for 4 nights at 3200 per night, total 12800",
    "booking reference WZ4471829 confirmed for 12/08/2026",
    "my flight AI 2109 lands at 14:35, checkout is at 11",
    "done, he has been paid",
    "of course, leaving them at the door",
]

func trafficEscalationRate() -> Double {
    let actor = ActorContext(trust: .standard, stage: .inquiry,
                             conversationID: "curve-\(UUID().uuidString)", senderID: "g")
    engine.resetBuffer(actor: actor)
    var escalated = 0
    for text in ordinary {
        let v = engine.evaluate(text, actor: actor, useConversationBuffer: true)
        if v.action == .allow || v.action == .hint, engine.shouldEscalate(v) { escalated += 1 }
        if !v.action.withholdsMessage { engine.remember(text, actor: actor) }
    }
    return Double(escalated) / Double(ordinary.count)
}

let costPerCall = 0.000075
let messagesPerMonth = 6_000_000.0

print("=== ESCALATION THRESHOLD TRADE-OFF ===")
print("cost model: $\(costPerCall)/call (gpt-oss-20b, reasoning_effort=low, measured)")
print("            6M messages/month at 10 000 active users\n")
print("sim floor  ordinary escalated  $/month   wave2 caught  ceiling  silent")

for floor in [0.0, 0.20, 0.24, 0.26, 0.28, 0.30, 0.34, 1.0] {
    EscalationAnalyser.escalationSimilarity = floor
    let rate = trafficEscalationRate()
    let monthly = messagesPerMonth * rate * costPerCall
    let w2 = RedTeamWave2Suite.run()
    let label = floor == 1.0 ? "off " : String(format: "%.2f", floor)
    print(String(format: "  %@      %@        $%7.0f      %2d/%d       %@   %d",
                 label, pct(rate), monthly,
                 w2.caught, w2.attacks.count, pct(w2.coverageCeiling), w2.silentMisses.count))
}

print("")
print("note: 'off' means the retrieval route is disabled and only the phrase lists")
print("      raise intentWithoutPayload. 0.00 means margin alone, no similarity floor.")
exit(0)
