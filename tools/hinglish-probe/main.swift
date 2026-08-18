// Does Tier 3 handle Hinglish abuse, if routing ever gets it there?
//
// The deterministic tiers score these at 0.028 with no suspicion, so nothing escalates and the
// adjudicator is never asked. That leaves an important question unanswered: is the gap only in
// routing, or is it in judgement too? The answer decides where the work goes — fixing a router
// is cheap, replacing a judge is not.
//
// This widens the abstain band so every message routes, then adjudicates for real.

import Foundation

let cases = [
    "Hiey frank , you dogshit peace of crack",
    "Chal chutiye",
    "Nikal bhosdike",
    "Gand mara",
    "Kya karogee bkl",
    "Pussy ass bitch",
    // Innocent Hinglish controls: a judge that flags these is worse than no judge.
    "Kya rate hai bhai",
    "bhai thoda discount ho jayega",
    "ghar saaf tha, thanks",
    "chal bhai booking kar dete hain",
]

let engine = ModerationEngine.shared
engine.configureJudgeFromSecrets()

guard engine.tier3Available else {
    FileHandle.standardError.write(Data("no adjudicator configured\n".utf8))
    exit(78)
}
print("adjudicator: \(engine.judge.identifier)\n")

// Force everything to route so the judge is actually consulted.
engine.abstainBand = 0.0...0.99

let group = DispatchGroup()
let lock = NSLock()
var rows: [(String, String, String, Double, String)] = []

for text in cases {
    group.enter()
    Task.detached {
        defer { group.leave() }
        let actor = ActorContext(conversationID: "probe-\(UUID().uuidString)",
                                 senderID: "probe-\(UUID().uuidString)")
        let verdict = engine.evaluate(text, actor: actor, useConversationBuffer: false)
        guard let (revised, judgement) = await engine.escalate(
            verdict: verdict, message: text, actor: actor
        ) else {
            lock.lock()
            rows.append((text, verdict.action.rawValue, "not escalated", 0, "-"))
            lock.unlock()
            return
        }
        lock.lock()
        rows.append((text, verdict.action.rawValue, revised.action.rawValue,
                     judgement.confidence, judgement.rationale))
        lock.unlock()
    }
}
group.wait()

// Note: `%s` in String(format:) expects a C string; passing a Swift String crashes.
print("message".padding(toLength: 42, withPad: " ", startingAt: 0)
      + "before".padding(toLength: 9, withPad: " ", startingAt: 0)
      + "after".padding(toLength: 9, withPad: " ", startingAt: 0)
      + "rationale")
print(String(repeating: "-", count: 118))
for (text, before, after, _, why) in rows.sorted(by: { $0.0 < $1.0 }) {
    let t = text.count > 40 ? String(text.prefix(38)) + ".." : text
    print(t.padding(toLength: 42, withPad: " ", startingAt: 0)
          + before.padding(toLength: 9, withPad: " ", startingAt: 0)
          + after.padding(toLength: 9, withPad: " ", startingAt: 0)
          + String(why.prefix(58)))
}
