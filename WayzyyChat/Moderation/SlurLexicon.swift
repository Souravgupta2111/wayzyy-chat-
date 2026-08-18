// Slur lexicon.
//
// Slurs are the one category where the target rule is deliberately bypassed: there is no
// target for which a caste, communal or racial slur is acceptable, so unlike profanity a
// slur does not need to be aimed at a person to be a violation. That makes this the
// highest-confidence rule in the system (0.97) and therefore the one that most needs to be
// curated carefully.
//
// The list loads from an external file rather than living only in source, for three reasons:
//
//   1. It needs review by people with the relevant linguistic and community knowledge,
//      which is a different review process from a code change.
//   2. It must be updatable without a deploy, because slurs evolve and regional coverage
//      expands faster than release cycles.
//   3. Keeping the operational list out of source control avoids shipping a searchable
//      catalogue in every clone of the repository.
//
// The compiled-in seed exists so the rule is never inert — an empty slur set silently
// disables the highest-confidence check in the engine, which is exactly the failure this
// file removes.

import Foundation

public struct SlurLexicon {

    /// Seed set. Deliberately narrow and unambiguous: terms whose only ordinary use is as an
    /// attack on caste, community, region, race, disability or sexuality. Anything with a
    /// legitimate register belongs in `DiscriminationRules.protectedCharacteristics`
    /// instead, where it carries no weight without an exclusion construction.
    ///
    /// India-weighted because that is the operating market and because caste and regional
    /// slurs are both the most common and the most legally consequential here.
    static let seed: Set<String> = [
        // caste
        "chamar", "bhangi", "chuhra", "mahar", "dhed", "neech jaat", "neechjaat",
        // communal
        "katua", "mulla", "landya", "kaffir",
        // regional and ethnic
        "chinki", "chinky", "madrasi", "bhaiya log", "bihari kutta",
        // racial
        "habshi", "kalu", "negro",
        // disability
        "langda", "andha kutta", "retard", "retarded",
        // sexuality and gender
        "chhakka", "gandu chhakka", "faggot", "tranny",
    ]

    /// Search order for an operational list. First readable file wins.
    static var searchPaths: [String] = [
        ProcessInfo.processInfo.environment["WAYZYY_SLUR_LEXICON"],
        "./config/slurs.json",
        "/etc/wayzyy/slurs.json",
    ].compactMap { $0 }

    /// Load the operational list, falling back to the seed.
    ///
    /// Terms are lowercased and, because romanised slurs have no standard spelling, each is
    /// also registered under its phonetic skeleton so variants match without being listed.
    @discardableResult
    public static func load() -> Set<String> {
        var terms = seed

        for path in searchPaths {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            if let list = try? JSONDecoder().decode([String].self, from: data) {
                terms.formUnion(list)
                break
            }
            // Also accept a newline-delimited file, which is easier for reviewers to edit.
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

    /// Skeleton forms of every slur, for spelling-variant matching. Short skeletons are
    /// discarded by `skeletonSet`, so this never introduces the collisions that a raw
    /// consonant spine would.
    public private(set) static var skeletons: Set<String> = []

    /// Number of loaded slur terms. Exposed so the gate can assert the rule is not inert —
    /// an empty set silently disables the highest-confidence check in the engine.
    public static var termCount: Int { Lex.slurTerms.count }

    /// True when any token in the message matches a slur skeleton.
    static func matchesSkeleton(_ skeletonWords: Set<String>) -> Bool {
        !skeletons.isEmpty && !skeletonWords.isDisjoint(with: skeletons)
    }

    /// Loaded once, on first use of the engine.
    static let bootstrap: Void = {
        _ = load()
    }()
}


