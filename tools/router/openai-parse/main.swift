// Parser check for the OpenAI moderation wire format, using a recorded response shape.
//
// Worth testing without a network call: a mapping bug here is silent. Wrong keys parse to zero,
// the classifier looks calibrated-but-quiet, and the only symptom is slightly worse routing that
// nobody attributes to a parser.

import Foundation

let sample = """
{
  "id": "modr-abc",
  "model": "omni-moderation-latest",
  "results": [{
    "flagged": true,
    "categories": { "harassment": true, "violence": false },
    "category_scores": {
      "harassment": 0.91,
      "harassment/threatening": 0.12,
      "hate": 0.44,
      "hate/threatening": 0.03,
      "violence": 0.21,
      "violence/graphic": 0.01,
      "sexual": 0.02,
      "sexual/minors": 0.001,
      "self-harm": 0.05,
      "self-harm/intent": 0.07,
      "self-harm/instructions": 0.002
    }
  }]
}
"""

guard let parsed = RemoteSafetyClassifier.WireFormat
    .openAIModeration.parse(Data(sample.utf8)) else {
    print("FAIL: did not parse")
    exit(1)
}

var ok = true
func expect(_ head: SafetyHead, _ want: Double, _ why: String) {
    let got = parsed[head] ?? 0
    let pass = abs(got - want) < 1e-9
    if !pass { ok = false }
    print("  \(pass ? "✓" : "✗") \(head.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))"
          + String(format: "%.3f  ", got) + why)
}

// Strongest of the contributing provider categories, not the last one read.
expect(.harassment, 0.91, "max(harassment .91, harassment/threatening .12, hate .44, hate/threatening .03)")
expect(.threat, 0.21, "max(harassment/threatening .12, hate/threatening .03, violence .21, violence/graphic .01)")
expect(.sexual, 0.02, "max(sexual .02, sexual/minors .001)")
expect(.selfHarm, 0.07, "max(self-harm .05, intent .07, instructions .002)")

// Absent heads must stay absent. A zero would read as evidence of innocence and could suppress
// the complaint veto, which is what protects a guest's right to complain bluntly.
for head in [SafetyHead.coercion, .scam, .legitimateComplaint] {
    let present = parsed[head] != nil
    if present { ok = false }
    print("  \(present ? "✗" : "✓") \(head.rawValue) left unset, not zeroed")
}

// A response with nothing in it must be a miss, so the caller falls back rather than caching an
// empty score map as though it were an answer.
let empty = RemoteSafetyClassifier.WireFormat.openAIModeration
    .parse(Data(#"{"results":[{"category_scores":{}}]}"#.utf8))
if empty != nil { ok = false }
print("  \(empty == nil ? "✓" : "✗") an empty score map is treated as no answer")

print(ok ? "\nPARSER OK" : "\nPARSER FAILED")
exit(ok ? 0 : 1)
