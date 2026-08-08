// Harness: measures the Tier-3 prompt size for a representative request.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

let engine = ModerationEngine.shared

let window = [
    "hi, is the villa free for the last weekend of the month",
    "great, we are four adults and two kids",
    "Always Keep Some House And Yard Guests Organised Always",
]
let actor = ActorContext(trust: .standard, stage: .inquiry, conversationID: "size", senderID: "b")
engine.resetBuffer(actor: actor)
var verdict: Verdict!
for m in window {
    verdict = engine.evaluate(m, actor: actor, useConversationBuffer: true)
    if !verdict.action.withholdsMessage { engine.remember(m, actor: actor) }
}

let request = JudgeRequest(
    window: window,
    priorScore: verdict.score,
    priorFindings: verdict.detections.map { "\($0.category.rawValue): \($0.canonical)" },
    bookingStage: actor.stage,
    trust: actor.trust,
    suspicions: verdict.suspicions,
    carriers: verdict.carriers
)

final class SizingJudge: SemanticJudge {
    let identifier = "sizing"
    var systemChars = 0
    var userChars = 0
    func judge(_ r: JudgeRequest) async -> JudgeVerdict {
        JudgeVerdict(decision: .abstain, confidence: 0, rationale: "",
                     intent: nil, source: identifier, latencyMs: 0)
    }
}

let systemPromptApprox = 2_050
let transcript = request.window
    .suffix(8)
    .enumerated()
    .map { "<message index=\"\($0.offset + 1)\">\(RemoteJudge.sanitise($0.element))</message>" }
    .joined(separator: "\n")

var sections: [String] = [
    "Booking stage: \(request.bookingStage.display). Sender trust: \(request.trust.display).",
    "Deterministic findings so far: \(request.priorFindings.isEmpty ? "none" : request.priorFindings.joined(separator: ", ")).",
]
if !request.suspicions.isEmpty {
    sections.append("Routed here because: " + request.suspicions.map(\.display).joined(separator: "; ") + ".")
}
if !request.carriers.isEmpty {
    sections.append("Decoded structure:\n" + request.carriers.map { "- \($0.summary)" }.joined(separator: "\n"))
}
sections.append("Recent messages from this sender, as quoted untrusted data:\n\(transcript)\n\nClassify the final message.")
let userContent = sections.joined(separator: "\n\n")

print("=== ONE TIER 3 CALL ===")
print("system prompt : ~\(systemPromptApprox) chars")
print("user content  : \(userContent.count) chars")
let totalChars = systemPromptApprox + userContent.count
let inputTokens = totalChars / 4
let outputTokens = 70
print("total input   : \(totalChars) chars  ≈ \(inputTokens) tokens")
print("output        : ≈ \(outputTokens) tokens (one JSON verdict)")
print("per call      : ≈ \(inputTokens + outputTokens) tokens")
print("")

print("=== WHAT WE NEED TO MEASURE ===")
let w2 = RedTeamWave2Suite.run()
let escalatedAttacks = w2.escalated
let escalatedInnocents = w2.innocentCallsCost
let rt = RedTeamSuite.run()
let wave1Misses = rt.missed
let baselineCorpus = BaselineComparison.runLocal().corpusSize

print("wave 2 escalated attacks   : \(escalatedAttacks)")
print("wave 2 escalated innocents : \(escalatedInnocents)")
print("wave 1 residual misses     : \(wave1Misses)")
print("LLM-only baseline corpus   : \(baselineCorpus)")
let minimal = escalatedAttacks + escalatedInnocents + wave1Misses
let full = minimal + baselineCorpus
print("")
print("minimum useful run : \(minimal) calls  ≈ \((minimal * (inputTokens + outputTokens)) / 1000)K tokens")
print("full run w/ baseline: \(full) calls  ≈ \((full * (inputTokens + outputTokens)) / 1000)K tokens")
print("")

print("=== FREE-TIER HEADROOM FOR THE FULL RUN ===")
func headroom(_ name: String, requestsPerDay: Int?, tokensPerDay: Int?) {
    var limits: [String] = []
    if let r = requestsPerDay { limits.append("\(r) calls/day → \(r / max(1, full)) full runs") }
    if let t = tokensPerDay {
        let calls = t / (inputTokens + outputTokens)
        limits.append("\(t / 1000)K tokens/day → \(calls) calls → \(calls / max(1, full)) full runs")
    }
    print("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(limits.joined(separator: "  |  "))")
}
headroom("Groq (per model)", requestsPerDay: 1_000, tokensPerDay: 100_000)
headroom("Cerebras", requestsPerDay: nil, tokensPerDay: 1_000_000)
headroom("OpenRouter free", requestsPerDay: 50, tokensPerDay: nil)
headroom("Gemini (current key)", requestsPerDay: 20, tokensPerDay: nil)
exit(0)
