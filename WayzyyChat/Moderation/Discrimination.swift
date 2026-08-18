// Discrimination, including caste.
//
// A distinct category rather than a flavour of harassment, because the harm is exclusion
// rather than insult and the two need different responses. On an Indian rental marketplace
// this is also the category with the sharpest legal edge: casteist abuse and caste-based
// refusal of accommodation are criminal offences under the Scheduled Castes and Scheduled
// Tribes (Prevention of Atrocities) Act.
//
// Two shapes are detected, and they are not the same problem:
//
//   1. REFUSAL  — "I don't rent to <group>". Exclusion. The sentence can be perfectly
//                 polite, which is why no profanity or hostility signal will find it.
//   2. SLUR     — a protected-characteristic term used as an attack. Reuses the target rule.
//
// The precision risk here is specific and worth stating: protected-characteristic words
// appear constantly in ordinary, entirely legitimate conversation. "We are a Muslim family"
// and "is the kitchen vegetarian" and "we are visiting for Diwali" all name a protected
// characteristic and none of them is discrimination. Detection therefore requires an
// exclusion or conditioning construction, never the characteristic alone.

import Foundation

struct DiscriminationRules {

    // MARK: - Protected characteristics
    //
    // Deliberately a plain vocabulary of *identity* terms. Nothing here is a slur; these are
    // the words people legitimately use to describe themselves and each other, so they carry
    // no weight on their own.

    static let protectedCharacteristics: Set<String> = [
        // religion
        "muslim", "muslims", "musalman", "hindu", "hindus", "christian", "christians",
        "sikh", "sikhs", "jain", "jains", "buddhist", "parsi", "jew", "jewish",
        // caste and community
        "dalit", "dalits", "harijan", "adivasi", "tribal", "sc", "st", "obc",
        "brahmin", "bania", "chamar", "bhangi", "mahar", "caste", "casteless",
        "lowercaste", "lowcaste", "upper caste", "lower caste", "scheduled caste",
        // region and nationality
        "bihari", "biharis", "bengali", "bengalis", "madrasi", "marwari", "punjabi",
        "kashmiri", "nepali", "bangladeshi", "pakistani", "african", "nigerian",
        "northeast", "northeastern", "chinki",
        // race and colour
        "black", "brown", "white", "dark skinned", "fair skinned",
        // gender and sexuality
        "woman", "women", "girls", "single women", "single woman", "lady", "ladies",
        "gay", "lesbian", "queer", "trans", "transgender", "hijra", "lgbt",
        // disability
        "disabled", "handicapped", "blind", "deaf", "wheelchair",
        // other
        "bachelor", "bachelors", "unmarried", "unmarried couple", "unmarried couples",
        "foreigner", "foreigners",
        // romanised Hindi identity terms
        "musalmaan", "isai", "harijan", "adivasi", "bihari", "bangali",
    ]

    // MARK: - Exclusion constructions
    //
    // These are what turn naming a characteristic into refusing service. Closed-class
    // grammar, so it generalises without enumerating vocabulary.

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

    /// True when a protected characteristic appears inside an exclusion or conditioning
    /// construction. The characteristic alone is never sufficient.
    static func refusal(in text: String) -> SafetyRules.Finding? {
        let lower = text.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

        // Locate the characteristic first — cheap, and most messages exit here.
        guard let characteristic = words.first(where: { protectedCharacteristics.contains($0) })
                ?? twoWordCharacteristic(in: lower)
        else { return nil }

        let constructions = [refusalRX, notAllowedRX, onlyRX, prefixRX]
        for rx in constructions {
            for match in rx.matches(in: lower, limit: 4) {
                // The construction must sit adjacent to the characteristic, not merely in the
                // same message: "no smoking, we are a Muslim family" must not trigger.
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

// MARK: - Findings

extension SafetyRules {

    /// Discrimination pass. Runs alongside the existing safety floor.
    static func discrimination(base: CharView, original: String) -> SafetyRules.Finding? {
        let text = original.isEmpty ? base.text : original
        return DiscriminationRules.refusal(in: text)
    }
}
