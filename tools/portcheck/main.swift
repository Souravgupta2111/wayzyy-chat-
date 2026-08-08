// Harness: checks the engine builds and behaves without Apple frameworks.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

func fallbackFold(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        if let multi = Lex.compatibilityFallbackString(scalar) {
            out += multi
        } else if let folded = Lex.compatibilityFallback(scalar) {
            out.unicodeScalars.append(folded)
        } else {
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

func fallbackDiacritic(_ s: String) -> String {
    let decomposed = s.decomposedStringWithCanonicalMapping
    var kept = String.UnicodeScalarView()
    for scalar in decomposed.unicodeScalars {
        let v = scalar.value
        let isCombining = (0x0300...0x036F).contains(v)
            || (0x1AB0...0x1AFF).contains(v)
            || (0x20D0...0x20FF).contains(v)
            || (0xFE20...0xFE2F).contains(v)
        if !isCombining { kept.append(scalar) }
    }
    return String(kept).lowercased()
}

var mismatches = 0
var checked = 0

print("=== NFKC FALLBACK vs APPLE ===")
let nfkcSamples = [
    "９８７６５４３２１０",
    "ＡＫＳＨＡＹ",
    "𝟗𝟖𝟕𝟔𝟓",
    "𝟫𝟪𝟩",
    "①②③④⑤⑥⑦⑧⑨",
    "⑴⑵⑶",
    "⁹⁸⁷⁰",
    "₉₈₇₀",
    "𝐀𝐊𝐒𝐇𝐀𝐘",
    "akshay",
    "9876543210",
    "🙂📞",
]
for sample in nfkcSamples {
    let apple = sample.precomposedStringWithCompatibilityMapping
    let ours = fallbackFold(sample)
    checked += 1
    let agree = apple == ours
    if !agree { mismatches += 1 }
    print("  \(agree ? "MATCH" : "DIFFER") '\(sample)'  apple='\(apple)'  fallback='\(ours)'")
}

print("\n=== DIACRITIC FALLBACK vs APPLE ===")
let diacriticSamples = [
    "AKSHAY", "Akshay", "ákshàÿ", "ÀÉÎÕÜ", "çñü",
    "akshay_goa_villa", "9876543210", "नौ आठ सात",
]
for sample in diacriticSamples {
    let apple = sample.folding(
        options: [.diacriticInsensitive, .caseInsensitive],
        locale: Locale(identifier: "en_US")
    )
    let ours = fallbackDiacritic(sample)
    checked += 1
    let agree = apple == ours
    if !agree { mismatches += 1 }
    print("  \(agree ? "MATCH" : "DIFFER") '\(sample)'  apple='\(apple)'  fallback='\(ours)'")
}

print("\n=== END-TO-END: does the payload still surface? ===")
let engine = ModerationEngine.shared
for payload in [
    "call me on ９８７６５４３２１０",
    "my number is 𝟗𝟖𝟕𝟔𝟓𝟒𝟑𝟐𝟏𝟎",
    "ring ①②③ then ④⑤⑥⑦⑧⑨⑩",
] {
    let actor = ActorContext(trust: .standard, stage: .inquiry,
                             conversationID: "port-\(UUID().uuidString)", senderID: "s")
    let v = engine.evaluate(payload, actor: actor, useConversationBuffer: false)
    let caught = v.action != .allow && v.action != .hint
    if !caught { mismatches += 1 }
    checked += 1
    print("  \(caught ? "CAUGHT" : "MISSED") \(v.action.rawValue)  \(payload)")
}

print("")
print("checked \(checked), mismatches \(mismatches)")
print(mismatches == 0 ? "FALLBACK IS EQUIVALENT — engine is Linux-portable"
                      : "FALLBACK DIVERGES — porting would silently lose coverage")
exit(mismatches == 0 ? 0 : 1)
