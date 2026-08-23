
import Foundation

struct DiscriminationRules {


    static let protectedCharacteristics: Set<String> = [
        "muslim", "muslims", "musalman", "hindu", "hindus", "christian", "christians",
        "sikh", "sikhs", "jain", "jains", "buddhist", "parsi", "jew", "jewish",
        "dalit", "dalits", "harijan", "adivasi", "tribal", "sc", "st", "obc",
        "brahmin", "bania", "chamar", "bhangi", "mahar", "caste", "casteless",
        "lowercaste", "lowcaste", "upper caste", "lower caste", "scheduled caste",
        "bihari", "biharis", "bengali", "bengalis", "madrasi", "marwari", "punjabi",
        "kashmiri", "nepali", "bangladeshi", "pakistani", "african", "nigerian",
        "northeast", "northeastern", "chinki",
        "black", "brown", "white", "dark skinned", "fair skinned",
        "woman", "women", "girls", "single women", "single woman", "lady", "ladies",
        "gay", "lesbian", "queer", "trans", "transgender", "hijra", "lgbt",
        "disabled", "handicapped", "blind", "deaf", "wheelchair",
        "bachelor", "bachelors", "unmarried", "unmarried couple", "unmarried couples",
        "foreigner", "foreigners",
        "musalmaan", "isai", "harijan", "adivasi", "bihari", "bangali",
    ]


    private static let refusalRX = RX(
        "discrimination-refusal",
        #"(?:no|not?\s+for|don'?t|do\s+not|won'?t|cannot|can'?t|never)\s+(?:rent|let|allow|accept|take|host|entertain|give|book)[^.!?]{0,30}?(?:to\s+)?"#
    )

    private static let onlyRX = RX(
        "discrimination-only",
        #"(?:only|strictly)\s+(?:for\s+)?(?:[a-z]+\s+){0,2}(?:families|vegetarian|vegetarians)?"#
    )

    private static let notAllowedRX = RX(
        "discrimination-not-allowed",
        #"(?:are|is)\s+not\s+(?:allowed|permitted|welcome|accepted)"#
    )

    private static let prefixRX = RX(
        "discrimination-prefix",
        #"\bno\s+(?:[a-z]+\s+){0,2}(?:allowed|permitted|please)?"#
    )

    static func refusal(in text: String) -> SafetyRules.Finding? {
        let lower = text.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

        guard let characteristic = words.first(where: { protectedCharacteristics.contains($0) })
                ?? twoWordCharacteristic(in: lower)
        else { return nil }

        let constructions = [refusalRX, notAllowedRX, onlyRX, prefixRX]
        for rx in constructions {
            for match in rx.matches(in: lower, limit: 4) {
                if let range = lower.range(of: characteristic),
                   abs(lower.distance(from: lower.startIndex, to: range.lowerBound) - match.end) <= 24 {
                    return SafetyRules.Finding(
                        category: .discrimination,
                        confidence: 0.88,
                        phrase: "service conditioned on a protected characteristic (\(characteristic))",
                        range: 0..<max(1, text.count),
                        target: .group
                    )
                }
            }
        }
        return nil
    }

    private static func twoWordCharacteristic(in lower: String) -> String? {
        protectedCharacteristics.first { $0.contains(" ") && lower.contains($0) }
    }
}


extension SafetyRules {

    static func discrimination(base: CharView, original: String) -> SafetyRules.Finding? {
        let text = original.isEmpty ? base.text : original
        return DiscriminationRules.refusal(in: text)
    }
}
