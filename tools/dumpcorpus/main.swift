// Harness: exports the anchor and adversarial corpora.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

struct Case: Encodable {
    let id: String
    let corpus: String
    let family: String
    let messages: [String]
    let shouldFlag: Bool
}

var cases: [Case] = []

for c in RedTeamCorpus.all {
    cases.append(Case(
        id: "w1-\(c.id)",
        corpus: "wave1",
        family: "\(c.family)",
        messages: c.messages.filter { !$0.isEmpty },
        shouldFlag: true
    ))
}

for c in RedTeamWave2.all {
    cases.append(Case(
        id: "w2-\(c.id)",
        corpus: "wave2",
        family: c.family.rawValue,
        messages: c.messages.filter { !$0.isEmpty },
        shouldFlag: c.shouldFlag
    ))
}

for t in AdversarialSuite.allCases {
    cases.append(Case(
        id: "reg-\(cases.count)",
        corpus: "regression",
        family: t.level.rawValue,
        messages: [t.text],
        shouldFlag: t.shouldFlag
    ))
}

let nonEmpty = cases.filter { !$0.messages.isEmpty }
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(nonEmpty)
let out = URL(fileURLWithPath: "/tmp/corpus.json")
try data.write(to: out)

let attacks = nonEmpty.filter(\.shouldFlag).count
print("wrote \(nonEmpty.count) cases to \(out.path)")
print("  attacks   : \(attacks)")
print("  innocent  : \(nonEmpty.count - attacks)")
for corpus in ["wave1", "wave2", "regression"] {
    let subset = nonEmpty.filter { $0.corpus == corpus }
    let a = subset.filter(\.shouldFlag).count
    print("  \(corpus): \(subset.count)  (\(a) attacks, \(subset.count - a) innocent)")
}
exit(0)
