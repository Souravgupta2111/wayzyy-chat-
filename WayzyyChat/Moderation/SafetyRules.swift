// Deterministic safety floor for threats, harassment, sexual content, self-harm, scams and brand impersonation.

import Foundation

enum SafetyRules {

    struct Finding {
        let category: ModCategory
        let confidence: Double
        let phrase: String
        let range: Range<Int>

        /// Typed decision attributes. Present when the deciding rule established them,
        /// so a reviewer can see *why* the finding stands, not only that it does.
        var lever: LeverClass? = nil
        var target: TargetClass? = nil
    }

    private static let coercionRX = RX(
        "coercion",
        #"(?:if|unless)\s+you\s+(?:don'?t|do\s+not|refuse|won'?t|dont)[^.!?]{0,60}?(?:i(?:'?ll|\s+will)?\s+)?(?:report|review|rate|1\s*star|one\s*star|complain|cancel|call\s+the\s+police)"#
    )
    private static let reviewThreatRX = RX(
        "review-threat",
        #"(?:bad|negative|1|one)\s*(?:star)?\s*review\s*(?:unless|if\s+you|until\s+you)"#
    )
    // The verb list is deliberately broad. Precision comes from the lever gate, not from
    // this pattern: "or i will report you" matches here and is then discarded because
    // reporting is a lawful remedy. Widening the conditional therefore costs no precision
    // and buys recall on phrasings we have not seen.
    private static let refundExtortRX = RX(
        "refund-extort",
        #"(?:refund|discount|free|money\s+back|pay\s+me)[^.!?]{0,40}?or\s+i(?:'?ll|\s+will)\s+(?:report|review|rate|complain|leave|tell|call|post|share|expose|contact|inform|trash|damage|ruin|destroy|wreck|break)"#
    )

    static var platformBrandTokens: Set<String> = ["wayzyy"]

    private static let urlCandidateRX = RX(
        "url-candidate",
        #"https?://[^\s<>"'\)\]\}]+"#
    )

    private static let maxScannedLinks = 10

    static var platformOwnedRegistrableDomains: Set<String> = ["wayzyy.com"]

    static var platformOwnedHosts: Set<String> {
        get { platformOwnedRegistrableDomains }
        set { platformOwnedRegistrableDomains = newValue }
    }

    static func isPlatformOwned(host: String) -> Bool {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        for owned in platformOwnedRegistrableDomains {
            if h == owned || h.hasSuffix("." + owned) { return true }
        }
        return false
    }

    private static func carriesBrand(_ s: String) -> Bool {
        let lower = s.lowercased()
        return platformBrandTokens.contains { lower.contains($0) }
    }

    private static func brandImpersonation(base: CharView, original: String) -> Finding? {
        let text = base.text
        let originalChars = Array(original)

        for m in urlCandidateRX.matches(in: text, limit: maxScannedLinks) {
            var candidate = m.text.lowercased()
            while let last = candidate.last, ".,;:!?".contains(last) { candidate.removeLast() }

            let components = URLComponents(string: candidate)
            let host = components?.host?.lowercased()
                ?? Self.manualHost(from: candidate)
            guard let host, !host.isEmpty else { continue }
            let userinfo = components?.user

            func finding(_ confidence: Double, _ phrase: String) -> Finding? {
                guard let orig = base.originalRange(m.start, m.end) else { return nil }
                return Finding(category: .scam, confidence: confidence, phrase: phrase, range: orig)
            }

            if let userinfo, carriesBrand(userinfo), !isPlatformOwned(host: host) {
                if let f = finding(
                    0.96,
                    "link displaying the platform name before @ while pointing at \(host)"
                ) { return f }
            }

            if isPlatformOwned(host: host) {
                if let orig = base.originalRange(m.start, m.end) {
                    let lo = max(0, min(orig.lowerBound, originalChars.count))
                    let hi = max(lo, min(orig.upperBound, originalChars.count))
                    let rawLink = String(originalChars[lo..<hi])
                    let authority = Self.authoritySection(of: rawLink)
                    if authority.contains(where: { !$0.isASCII }) {
                        if let f = finding(
                            0.96,
                            "link using look-alike characters to imitate the platform domain"
                        ) { return f }
                    }
                }
                continue
            }

            if carriesBrand(host) {
                if let f = finding(0.96, "link impersonating the platform: \(host)") { return f }
            }

            if host.contains("xn--") {
                if let f = finding(
                    0.82,
                    "link using an encoded international domain: \(host)"
                ) { return f }
            }
        }
        return nil
    }

    private static func manualHost(from candidate: String) -> String? {
        guard let schemeEnd = candidate.range(of: "://")?.upperBound else { return nil }
        let rest = candidate[schemeEnd...]
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let hostPart = authority.split(separator: "@").last ?? authority
        return hostPart.split(separator: ":").first.map(String.init)
    }

    private static func authoritySection(of link: String) -> String {
        guard let schemeEnd = link.range(of: "://")?.upperBound else { return link }
        let rest = link[schemeEnd...]
        return String(rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
    }

    static var slurTerms: Set<String> {
        get { Lex.slurTerms }
        set {
            Lex.requireMutable("Slur term assignment")
            Lex.slurTerms = newValue
        }
    }

    private static func profanity(alpha: CharView, alphaCompact: CharView) -> Finding? {
        let tokens = Canonicalizer.tokenize(alpha).filter(\.isWord)
        guard !tokens.isEmpty else { return nil }
        let words = tokens.map(\.text)

        func rangeFor(_ index: Int) -> Range<Int>? {
            alpha.originalRange(tokens[index].start, tokens[index].end)
        }

        // Multi-word slurs ("neech jaat", "bihari kutta") cannot be caught by token
        // comparison, so the phrase forms are checked against the joined text first.
        let joined = words.joined(separator: " ")
        for phrase in Lex.slurTerms where phrase.contains(" ") && joined.contains(phrase) {
            let upper = max(1, (alpha.offsets.last ?? 0) + 1)
            return Finding(category: .harassment, confidence: 0.97,
                           phrase: "slur", range: 0..<upper, target: .group)
        }

        // Spelling variants, via the phonetic skeleton. Short skeletons are discarded when
        // the set is built, so this cannot reintroduce the `tatti` → "t" class of collision.
        let skeletonWords = Set(words.map { HinglishFold.skeleton($0) })
        if SlurLexicon.matchesSkeleton(skeletonWords) {
            let upper = max(1, (alpha.offsets.last ?? 0) + 1)
            return Finding(category: .harassment, confidence: 0.97,
                           phrase: "slur (skeleton match)", range: 0..<upper, target: .group)
        }

        for (i, w) in words.enumerated() where Lex.slurTerms.contains(w) {
            guard let r = rangeFor(i) else { continue }
            return Finding(category: .harassment, confidence: 0.97, phrase: "slur", range: r)
        }

        let window = 4
        for (i, w) in words.enumerated() {
            let indic = Lex.profanityIndic.contains(w)
            let strong = Lex.profanityStrong.contains(w)
            let mild = Lex.profanityMild.contains(w)
            guard indic || strong || mild else { continue }

            let lo = max(0, i - window), hi = min(words.count - 1, i + window)
            var person = false, property = false
            for j in lo...hi where j != i {
                if Lex.personTargets.contains(words[j]) { person = true }
                if Lex.propertyTargets.contains(words[j]) { property = true }
            }

            if property && !person { continue }
            if !person { continue }

            guard let r = rangeFor(i) else { continue }
            let confidence: Double = indic ? 0.94 : (strong ? 0.90 : 0.74)
            return Finding(
                category: .harassment,
                confidence: confidence,
                phrase: "profanity directed at a person",
                range: r
            )
        }

        let filler: Set<Character> = ["*", "#", "-", "_", ".", "+", "~", "^"]
        let destarred = String(alpha.text.filter { !filler.contains($0) })
        if destarred != alpha.text {
            for w in destarred.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let word = String(w)
                let indic = Lex.profanityIndic.contains(word)
                let strong = Lex.profanityStrong.contains(word)
                guard indic || strong || Lex.slurTerms.contains(word) else { continue }
                guard words.contains(where: { Lex.personTargets.contains($0) }) else { continue }
                let upper = max(1, (alpha.offsets.last ?? 0) + 1)
                return Finding(
                    category: .harassment,
                    confidence: indic ? 0.94 : 0.90,
                    phrase: "profanity directed at a person",
                    range: 0..<upper
                )
            }
        }
        return nil
    }

    private static let agentRequiredThreats: Set<String> = [
        "kill you", "hurt you", "beat you up", "break your legs", "smash your face",
        "burn your house", "you will regret",
    ]

    private static let visitThreats: Set<String> = [
        "come to your house",
    ]

    private static let firstPersonAgents: Set<String> = [
        "i", "im", "ive", "ill", "id", "we", "well", "weve", "were", "us", "me", "my",
        "main", "mai", "mein", "hum", "humne", "maine",
    ]

    private static let offerModals: Set<String> = [
        "can", "could", "may", "shall", "should", "might", "would",
    ]

    private static let serviceVerbs: Set<String> = [
        "inspect", "repair", "fix", "check", "clean", "service", "servicing", "maintenance",
        "deliver", "collect", "drop", "install", "replace", "sort", "arrange", "help",
        "bring", "pick", "show", "handover", "hand", "meet", "assist",
    ]

    private static let targetRequiredHarassment: Set<String> = [
        "worthless", "moron", "imbecile", "pathetic loser", "disgusting person",
    ]

    private static func words(in text: String, before index: Int, limit: Int) -> [String] {
        let prefix = String(text.prefix(index))
        return prefix
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .suffix(limit)
            .map(String.init)
    }

    static func threatContextHolds(_ phrase: String, at start: Int, in text: String) -> Bool {
        let needsAgent = agentRequiredThreats.contains(phrase)
        let isVisit = visitThreats.contains(phrase)
        guard needsAgent || isVisit else { return true }

        let preceding = words(in: text, before: start, limit: 8)
        guard preceding.contains(where: { firstPersonAgents.contains($0) }) else {
            return false
        }
        guard isVisit else { return true }

        let offered = preceding.contains { offerModals.contains($0) }
        let servicing = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { serviceVerbs.contains(String($0)) }
        return !(offered || servicing)
    }

    static func harassmentTargetHolds(_ phrase: String, words: [String]) -> Bool {
        guard targetRequiredHarassment.contains(phrase) else { return true }
        return words.contains { Lex.personTargets.contains($0) }
    }

    private static let phishingMechanismTerms: Set<String> = [
        "link", "links", "click", "clicking", "url", "website", "portal",
        "otp", "password", "passcode", "pin", "cvv", "cvc", "code",
        "card", "debit", "credit", "netbanking", "login", "signin",
        "upi", "wallet", "paytm", "gpay", "phonepe", "transfer", "gift",
    ]

    private static func hasPhishingMechanism(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("http") || lower.contains("www.") { return true }
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.contains { phishingMechanismTerms.contains($0) }
    }

    static func semanticFindingHolds(_ finding: Finding, text: String) -> Bool {
        switch finding.category {
        case .harassment:
            let words = text
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            if words.contains(where: { Lex.personTargets.contains($0) }) { return true }
            return EscalationAnalyser.addressesPersonNativeScript(text)

        case .scam:
            return hasPhishingMechanism(text)

        default:
            return true
        }
    }

    // Skeleton sets, folded once at load. One entry covers every spelling of a word and
    // both scripts, because Devanagari is transliterated before folding.
    private static let indicProfanitySkeletons = HinglishFold.skeletonSet(Lex.profanityIndic)

    /// Romanised-Hindi and Devanagari profanity, matched in skeleton space so spelling
    /// variance costs nothing. The target rule still applies: profanity aimed at the
    /// property is a crude review, not abuse.
    ///
    /// Targets are deliberately checked on the **surface** form, not in skeleton space.
    /// Target terms are short — `tu` reduces to `"t"`, `tera` to `"tr"` — so folding them
    /// would let ordinary words like `to` and `the` satisfy the person requirement and
    /// quietly disable the rule that makes this whole layer safe.
    private static func skeletonProfanity(_ skeleton: CharView, surface: String) -> Finding? {
        guard !skeleton.isEmpty else { return nil }
        let skeletonWords = Set(skeleton.text.split(separator: " ").map(String.init))
        guard !skeletonWords.isEmpty,
              !skeletonWords.isDisjoint(with: indicProfanitySkeletons) else { return nil }

        let surfaceWords = surface
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let person = surfaceWords.contains { Lex.personTargets.contains($0) }
            || EscalationAnalyser.addressesPersonNativeScript(surface)
        let property = surfaceWords.contains { Lex.propertyTargets.contains($0) }

        guard person else { return nil }
        if property && !person { return nil }

        let upper = max(1, (skeleton.offsets.last ?? 0) + 1)
        return Finding(
            category: .harassment,
            confidence: 0.94,
            phrase: "profanity directed at a person (skeleton match)",
            range: 0..<upper,
            target: .person
        )
    }

    static func evaluate(
        base: CharView,
        alpha: CharView,
        alphaCompact: CharView,
        skeleton: CharView? = nil,
        original: String = ""
    ) -> [Finding] {
        let text = base.text
        guard !text.isEmpty else { return [] }
        var findings: [Finding] = []

        if let phish = brandImpersonation(base: base, original: original.isEmpty ? text : original) {
            findings.append(phish)
        }
        if let bias = discrimination(base: base, original: original) {
            findings.append(bias)
        }
        if let abuse = profanity(alpha: alpha, alphaCompact: alphaCompact) {
            findings.append(abuse)
        } else if let skeleton, let abuse = skeletonProfanity(skeleton, surface: text) {
            // Only consulted when the surface-form pass found nothing, so the skeleton
            // view adds recall on unseen spellings without changing existing verdicts.
            findings.append(abuse)
        }

        let messageWords = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0) }

        func scan(
            _ phrases: [String],
            _ category: ModCategory,
            _ confidence: Double,
            gate: ((String, Int) -> Bool)? = nil
        ) {
            for phrase in phrases {
                guard let r = text.range(of: phrase) else { continue }
                let start = text.distance(from: text.startIndex, to: r.lowerBound)
                let end = text.distance(from: text.startIndex, to: r.upperBound)
                if let gate, !gate(phrase, start) { continue }
                guard let orig = base.originalRange(start, end) else { continue }
                findings.append(Finding(category: category, confidence: confidence, phrase: phrase, range: orig))
                return
            }
        }

        scan(Lex.selfHarmPhrases, .selfHarm, 0.90)
        scan(Lex.threatPhrases, .threat, 0.93) { phrase, start in
            threatContextHolds(phrase, at: start, in: text)
        }
        scan(Lex.sexualPhrases, .sexual, 0.88)
        scan(Lex.harassmentPhrases, .harassment, 0.74) { phrase, _ in
            harassmentTargetHolds(phrase, words: messageWords)
        }
        scan(Lex.scamPhrases, .scam, 0.82)

        // Coercion is a two-part test: a conditional demand AND illegitimate leverage.
        // A conditional demand paired with a lawful remedy — an honest review, a platform
        // report, a bank dispute, a police report of a real crime — is a customer
        // exercising a right and produces no finding. The conditional still raises a
        // router suspicion, so genuinely novel leverage reaches Tier 3 for adjudication.
        let leverClass = LeverTaxonomy.classify(text)
        if leverClass == .illegitimate {
            scan(Lex.coercionPhrases, .coercion, 0.78)

            for rx in [coercionRX, reviewThreatRX, refundExtortRX] {
                guard findings.first(where: { $0.category == .coercion }) == nil else { break }
                for m in rx.matches(in: text, limit: 1) {
                    guard let orig = base.originalRange(m.start, m.end) else { continue }
                    findings.append(Finding(category: .coercion, confidence: 0.88,
                                            phrase: m.text, range: orig,
                                            lever: .illegitimate))
                }
            }
        }

        // Stamp the established lever on every coercion finding so the reason is auditable.
        findings = findings.map { f in
            guard f.category == .coercion, f.lever == nil else { return f }
            var out = f
            out.lever = leverClass
            return out
        }

        return findings
    }
}
