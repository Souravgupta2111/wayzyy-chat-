// Harness: compares lexical and embedding retrieval backends.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

func pct(_ d: Double) -> String { String(format: "%+.3f", d) }

let corpus = IntentExemplars.all.map(\.text) + IntentExemplars.negatives
let lexical = SemanticRetriever(vectoriser: LexicalVectoriser(corpus: corpus))

print("embedding the exemplar corpus (\(corpus.count) anchors), one-off cost…")
let started = Date()
guard let embedded = SemanticRetriever.embeddingBacked() else {
    print("no embedding endpoint reachable — is `ollama serve` running with nomic-embed-text?")
    exit(1)
}
print(String(format: "ready in %.1f s\n", Date().timeIntervalSince(started)))

struct Probe {
    let label: String
    let text: String
    let innocent: Bool
}

let probes: [Probe] = [
    .init(label: "email→gmail", text: "my email preferences are set already", innocent: true),
    .init(label: "reach→reach out", text: "we will reach by 7 pm", innocent: true),
    .init(label: "villa anchor", text: "hi, is the villa available next weekend", innocent: true),
    .init(label: "villa sleeps", text: "that works, the villa sleeps 8", innocent: true),
    .init(label: "noise match", text: "done, he has been paid", innocent: true),
    .init(label: "guest count", text: "hello! yes it is, for how many guests", innocent: true),
    .init(label: "hindi thanks", text: "bahut dhanyavaad, teen raat ka payment ho gaya hai", innocent: true),
    .init(label: "app reminder", text: "does this app send me a reminder before check in", innocent: true),
    .init(label: "taxi payment", text: "Abhishek ko 430 rupay dedena for the taxi", innocent: true),
    .init(label: "gate code", text: "the gate code will be shared on the app on the morning of arrival", innocent: true),

    .init(label: "profile bio", text: "my number is in my profile bio just check there", innocent: false),
    .init(label: "google me", text: "google akshay verma goa villa you will find my contact", innocent: false),
    .init(label: "guess handle", text: "my handle is the same on every app you can guess it", innocent: false),
    .init(label: "solicit", text: "just send me your number and i will text you straight away", innocent: false),
    .init(label: "gate sign", text: "the number painted on the gate is the one to use", innocent: false),
    .init(label: "review reply", text: "i replied to a review last month with my details go read it", innocent: false),
    .init(label: "green icon", text: "you know the app with the green icon, I am on there with the same name", innocent: false),
    .init(label: "deal direct", text: "they take a huge cut, everyone I host just deals with me directly now", innocent: false),
]

print("                                    LEXICAL          EMBEDDING")
print("case                          sim    margin      sim    margin    verdict")
print(String(repeating: "-", count: 76))

var lexBadInnocent = 0, embBadInnocent = 0
var lexWeakAttack = 0, embWeakAttack = 0

for p in probes {
    let l = lexical.retrieve(p.text)
    let e = embedded.retrieve(p.text)
    let lm = l?.margin ?? -1, em = e?.margin ?? -1
    let ls = l?.similarity ?? 0, es = e?.similarity ?? 0

    let lEsc = ls >= 0.24 && lm >= 0.05
    let eEsc = es >= 0.24 && em >= 0.05

    var note = ""
    if p.innocent {
        if lEsc { lexBadInnocent += 1 }
        if eEsc { embBadInnocent += 1 }
        note = lEsc && !eEsc ? "FIXED" : (!lEsc && eEsc ? "REGRESSED" : (lEsc ? "both bad" : "both ok"))
    } else {
        if !lEsc { lexWeakAttack += 1 }
        if !eEsc { embWeakAttack += 1 }
        note = !lEsc && eEsc ? "gained" : (lEsc && !eEsc ? "LOST" : (lEsc ? "both ok" : "both weak"))
    }

    print(String(format: "%-26s %6.3f  %@   %6.3f  %@   %@",
                 ((p.innocent ? "· " : "! ") + p.label as NSString).utf8String!,
                 ls, (pct(lm) as NSString), es, (pct(em) as NSString), (note as NSString)))
}

let innocents = probes.filter(\.innocent).count
let attacks = probes.count - innocents
print(String(repeating: "-", count: 76))
print("")
print("INNOCENT messages wrongly looking suspicious (lower is better)")
print("  lexical    \(lexBadInnocent)/\(innocents)")
print("  embedding  \(embBadInnocent)/\(innocents)")
print("")
print("ATTACKS Tier 2 fails to notice (lower is better)")
print("  lexical    \(lexWeakAttack)/\(attacks)")
print("  embedding  \(embWeakAttack)/\(attacks)")
print("")

let lexScore = lexBadInnocent + lexWeakAttack
let embScore = embBadInnocent + embWeakAttack
print("total errors: lexical \(lexScore), embedding \(embScore)")
print(embScore < lexScore
      ? "→ embeddings are better on this set"
      : (embScore == lexScore ? "→ no measured difference" : "→ lexical is better; do not switch"))
exit(0)
