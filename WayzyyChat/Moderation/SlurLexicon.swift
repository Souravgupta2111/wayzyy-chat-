
import Foundation

public struct SlurLexicon {

    static let seed: Set<String> = [
        "chamar", "bhangi", "chuhra", "mahar", "dhed", "neech jaat", "neechjaat",
        "katua", "mulla", "landya", "kaffir",
        "chinki", "chinky", "madrasi", "bhaiya log", "bihari kutta",
        "habshi", "kalu", "negro",
        "langda", "andha kutta", "retard", "retarded",
        "chhakka", "gandu chhakka", "faggot", "tranny",
    ]

    static var searchPaths: [String] = [
        ProcessInfo.processInfo.environment["WAYZYY_SLUR_LEXICON"],
        "./config/slurs.json",
        "/etc/wayzyy/slurs.json",
    ].compactMap { $0 }

    @discardableResult
    public static func load() -> Set<String> {
        var terms = seed

        for path in searchPaths {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            if let list = try? JSONDecoder().decode([String].self, from: data) {
                terms.formUnion(list)
                break
            }
            if let text = String(data: data, encoding: .utf8) {
                let lines = text
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                if !lines.isEmpty {
                    terms.formUnion(lines)
                    break
                }
            }
        }

        let normalised = Set(terms.map { $0.lowercased() })
        Lex.requireMutable("Slur lexicon installation")
        Lex.slurTerms = normalised
        skeletons = HinglishFold.skeletonSet(normalised)
        return normalised
    }

    public private(set) static var skeletons: Set<String> = []

    public static var termCount: Int { Lex.slurTerms.count }

    static func matchesSkeleton(_ skeletonWords: Set<String>) -> Bool {
        !skeletons.isEmpty && !skeletonWords.isDisjoint(with: skeletons)
    }

    static let bootstrap: Void = {
        _ = load()
    }()
}


