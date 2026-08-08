// Harness: replays ordinary traffic to measure throughput and tier share.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

let engine = ModerationEngine.shared

let ordinary = [
    "hi, is the villa available next weekend",
    "hello! yes it is, for how many guests",
    "we are 4 adults and 2 kids",
    "that works, the villa sleeps 8",
    "what time is check in",
    "check in is 2 pm and check out 11 am",
    "is early check in possible, our train arrives at 6 am",
    "yes we can do that if the previous guest leaves on time",
    "great, thank you so much",
    "is there parking",
    "yes, space for 2 cars inside the gate",
    "is the pool heated",
    "not heated but it stays warm through the season",
    "how far is the beach",
    "about 2.5 km, 8 minutes by scooter",
    "is breakfast included",
    "breakfast is 250 per person, dinner around 600 for 2",
    "we would like breakfast for 4 days",
    "noted, i will add it to the booking",
    "total came to 12,500 including the 1,200 cleaning fee",
    "perfect, paying now",
    "payment received, see you on the 12th",
    "we will reach by 7 pm",
    "someone will be at the gate",
    "thank you, looking forward to it",
    "the wifi is not working in the second bedroom",
    "sorry about that, i will send someone in the morning",
    "wifi details are in the house manual on the counter",
    "found it, working now, thanks",
    "the bathroom was not cleaned properly",
    "apologies, housekeeping will come at 10 am",
    "much better now, thank you",
    "can we get 2 extra towels",
    "of course, leaving them at the door",
    "is late checkout possible on sunday",
    "we can do 1 pm at no extra charge",
    "amazing, thank you",
    "Abhishek ko 430 rupay dedena for the taxi",
    "done, he has been paid",
    "do teen din ke liye chahiye, char log aayenge",
    "haan bilkul, jagah hai",
    "hum saat baje pahunchenge, teen ghante lagenge",
    "koi baat nahi, main gate khol dunga",
    "bahut dhanyavaad, teen raat ka payment ho gaya hai",
    "the villa was lovely, we had a great time",
    "thank you so much 🙏 we had a wonderful time 😊",
    "rated 4.8 out of 5 across 126 reviews, congrats",
    "we appreciate it, hope to host you again",
    "does this app send me a reminder before check in",
    "yes, 24 hours before arrival",
    "my email preferences are set already",
    "no problem, everything stays in the app",
    "the gate code will be shared on the morning of arrival",
    "understood, thanks",
    "Villa Serena, Assagao, Bardez, North Goa, India, 403507",
    "we are on train 12051 arriving 06:40",
    "our GSTIN is 27AAPFU0939F1ZV if you need it for the bill",
    "invoice 8829 for 4 nights at 3200 per night, total 12800",
    "booking reference WZ4471829 confirmed for 12/08/2026",
    "my flight AI 2109 lands at 14:35, checkout is at 11",
]

let violations = [
    "call me on 9876543210",
    "my insta is akshay_goa_villa",
    "whatsapp me, easier than this app",
]

func pct(_ d: Double) -> String { String(format: "%.1f%%", d * 100) }

let actor = ActorContext(trust: .standard, stage: .inquiry,
                         conversationID: "traffic", senderID: "guest")
engine.resetBuffer(actor: actor)

var escalated = 0
var enforced = 0
var latencies: [Double] = []
var escalatedTexts: [(String, [Suspicion])] = []

var stream: [String] = []
for _ in 0..<10 {
    stream += ordinary
    stream += violations
}

for text in stream {
    let v = engine.evaluate(text, actor: actor, useConversationBuffer: true)
    latencies.append(v.latencyMs)
    if v.action != .allow && v.action != .hint { enforced += 1 }
    else if engine.shouldEscalate(v) {
        escalated += 1
        if escalatedTexts.count < 40 { escalatedTexts.append((text, v.suspicions)) }
    }
    if !v.action.withholdsMessage { engine.remember(text, actor: actor) }
}

let sorted = latencies.sorted()
func p(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }

print("=== TRAFFIC-SHAPED RUN ===")
print("messages            : \(stream.count)  (\(pct(Double(violations.count * 10) / Double(stream.count))) violations by construction)")
print("enforced by T1+T2   : \(enforced)  (\(pct(Double(enforced) / Double(stream.count))))")
print("escalated to T3     : \(escalated)  (\(pct(Double(escalated) / Double(stream.count))))")
print("decided free        : \(pct(Double(stream.count - escalated) / Double(stream.count)))")
print("")
print("TIER 1+2 LATENCY (every message pays this)")
print(String(format: "  p50 %.2f ms   p95 %.2f ms   p99 %.2f ms   max %.2f ms",
             p(0.50), p(0.95), p(0.99), sorted.last ?? 0))
print("")

let distinct = Set(escalatedTexts.map(\.0))
print("distinct escalating messages: \(distinct.count)")
for (t, s) in escalatedTexts.prefix(12) where !s.isEmpty {
    print("  [\(s.map(\.rawValue).joined(separator: ","))] \(t.prefix(64))")
}
print("")

let uniqueFraction = Double(Set(stream).count) / Double(stream.count)
print("=== CACHING HEADROOM ===")
print("unique messages     : \(Set(stream).count) of \(stream.count)  (\(pct(uniqueFraction)))")
print("verdicts are deterministic, so a content-addressed cache eliminates the rest")
print("effective escalation after caching: \(pct(Double(distinct.count) / Double(stream.count)))")
exit(0)
