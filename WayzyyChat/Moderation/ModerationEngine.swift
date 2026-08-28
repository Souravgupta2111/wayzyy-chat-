
import Foundation

final class ModerationEngine {

    static let shared: ModerationEngine = {
        _ = SlurLexicon.bootstrap
        _ = NativeScriptSafety.register
        let engine = ModerationEngine()
        engine.abuseRouter = AbuseRouter.discover()
        Lex.seal()
        return engine
    }()

    private let canonicalizer = Canonicalizer()
    private let scorer = Scorer()


    struct Dependencies {
        let retriever: SemanticRetriever
        let actorSignals: ActorSignalStore
        let safetyClassifier: SafetyClassifier
        let judge: SemanticJudge
        let abstainBand: ClosedRange<Double>
        let tier2Enabled: Bool

        var tier3Available: Bool { !(judge is FixtureJudge) }
    }

    private let configLock = NSLock()

    private var _retriever = SemanticRetriever()
    private var _actorSignals = ActorSignalStore()
    private var _safetyClassifier: SafetyClassifier = SignalDerivedSafetyClassifier()
    private var _judge: SemanticJudge = FixtureJudge()
    private var _abstainBand: ClosedRange<Double> = 0.10...0.62
    private var _tier2Enabled = true

    func dependencies() -> Dependencies {
        configLock.lock()
        defer { configLock.unlock() }
        return Dependencies(
            retriever: _retriever,
            actorSignals: _actorSignals,
            safetyClassifier: _safetyClassifier,
            judge: _judge,
            abstainBand: _abstainBand,
            tier2Enabled: _tier2Enabled
        )
    }

    var retriever: SemanticRetriever {
        get { configLock.lock(); defer { configLock.unlock() }; return _retriever }
        set { configLock.lock(); _retriever = newValue; configLock.unlock() }
    }

    var actorSignals: ActorSignalStore {
        get { configLock.lock(); defer { configLock.unlock() }; return _actorSignals }
        set { configLock.lock(); _actorSignals = newValue; configLock.unlock() }
    }

    var safetyClassifier: SafetyClassifier {
        get { configLock.lock(); defer { configLock.unlock() }; return _safetyClassifier }
        set { configLock.lock(); _safetyClassifier = newValue; configLock.unlock() }
    }

    var judge: SemanticJudge {
        get { configLock.lock(); defer { configLock.unlock() }; return _judge }
        set { configLock.lock(); _judge = newValue; configLock.unlock() }
    }

    var tier3Available: Bool { dependencies().tier3Available }

    private(set) var abuseRouter: AbuseRouter?

    var abstainBand: ClosedRange<Double> {
        get { configLock.lock(); defer { configLock.unlock() }; return _abstainBand }
        set { configLock.lock(); _abstainBand = newValue; configLock.unlock() }
    }

    var tier2Enabled: Bool {
        get { configLock.lock(); defer { configLock.unlock() }; return _tier2Enabled }
        set { configLock.lock(); _tier2Enabled = newValue; configLock.unlock() }
    }

    static let maxAnalysedCharacters = 4_000
    static let expensiveTierCharacterLimit = 600
    static let bufferAssemblyCharacterLimit = 1_200

    static let safetyScanCharacterLimit = 6_000
    static let safetyChunkSize = 600
    static let safetyChunkOverlap = 120
    static let safetyMaxChunks = 10

    private var _buffers = ConversationBuffers()

    var buffers: ConversationBuffers {
        get { configLock.lock(); defer { configLock.unlock() }; return _buffers }
        set { configLock.lock(); _buffers = newValue; configLock.unlock() }
    }

    func remember(_ text: String, actor: ActorContext) {
        buffers.remember(text, actor: actor)
    }


    func report(sender: String, at now: Date = Date()) {
        actorSignals.recordReport(against: sender, at: now)
    }

    func block(sender: String, at now: Date = Date()) {
        actorSignals.recordBlock(of: sender, at: now)
    }

    func notePlatformPriors(sender: String, count: Int) {
        actorSignals.notePlatformPriors(sender: sender, count: count)
    }

    func platformPriors(sender: String) -> Int {
        actorSignals.platformPriors(for: sender)
    }

    func behaviouralRisk(sender: String, conversation: String) -> ActorRisk {
        actorSignals.risk(for: sender, conversation: conversation)
    }

    func resetBuffer(actor: ActorContext) {
        buffers.reset(actor: actor)
        actorSignals.reset(sender: actor.senderID)
    }

    var trackedConversationCount: Int { buffers.trackedCount }

    private func recentContext(_ actor: ActorContext) -> [String] {
        buffers.recent(actor)
    }

    func evaluate(
        _ original: String,
        actor: ActorContext = .default,
        advisoryOnly: Bool = false,
        useConversationBuffer: Bool = true
    ) -> Verdict {
        let started = DispatchTime.now().uptimeNanoseconds

        let policy = Policy.snapshot()

        let deps = dependencies()

        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .clean(original, latencyMs: elapsedMs(since: started))
        }

        let fullLength = original.count
        let analysed: String
        var truncated = false
        if fullLength > Self.maxAnalysedCharacters {
            analysed = String(original.prefix(Self.maxAnalysedCharacters))
            truncated = true
        } else {
            analysed = original
        }
        let allowExpensiveTiers = analysed.count <= Self.expensiveTierCharacterLimit

        let views = canonicalizer.build(analysed)
        let contextResult = NumericContext.analyze(views.base)

        let transforms = views.allTransforms
        let effort = Canonicalizer.effort(for: transforms)

        let signals = Signals.compute(base: views.base, alpha: views.alpha, compact: views.compact)

        var detections: [Detection] = []

        let allDigits = views.digits.text
        let launderedPhone = Extractors.isHighConfidencePhone(allDigits)

        let maskedPhones = Extractors.phones(
            digitView: views.digitsMasked, suppressed: false, effort: effort
        )
        let rawPhones = Extractors.phones(
            digitView: views.digits, suppressed: !launderedPhone, effort: effort
        )

        let suppressedOnly = maskedPhones.isEmpty && !rawPhones.isEmpty && !launderedPhone
        detections += maskedPhones.isEmpty ? rawPhones : maskedPhones

        if detections.filter({ $0.category == .phone }).isEmpty, signals.hasContactIntent {
            let stream = views.digitsMasked.text.isEmpty
                ? views.digits.text
                : views.digitsMasked.text
            if stream.count >= 10, stream.count <= 13 {
                let offsets = views.digitsMasked.text.isEmpty
                    ? views.digits.offsets
                    : views.digitsMasked.offsets
                let lo = offsets.min() ?? 0
                let hi = (offsets.max() ?? lo) + 1
                detections.append(Detection(
                    category: .phone,
                    range: lo..<min(hi, Array(analysed).count),
                    surface: "",
                    canonical: stream,
                    confidence: 0.86,
                    transforms: views.digitsMasked.transforms,
                    effort: effort + 2,
                    reason: "Sender labelled this as their number and gave \(stream.count) digits"
                ))
            }
        }

        if detections.isEmpty {
            detections += Extractors.phones(
                digitView: views.compactDigits, suppressed: false, effort: effort
            )
        }

        if detections.isEmpty {
            detections += Extractors.phones(
                digitView: views.romanDigits, suppressed: false, effort: effort
            )
        }

        if detections.isEmpty {
            detections += Extractors.phones(
                digitView: views.digitsReversed, suppressed: false, effort: effort, reversed: true
            )
        }

        detections += Extractors.emails(
            base: views.base,
            separators: views.separators,
            hasMailKeyword: signals.mailKeyword,
            effort: effort
        )
        detections += Extractors.urls(base: views.base, effort: effort)
        detections += Extractors.urls(base: views.separators, effort: effort)
        detections += Extractors.urls(base: views.separatorsAlt, effort: effort)
        detections += Extractors.spelledURLs(in: analysed, effort: effort)
        detections += Extractors.emails(
            base: views.separatorsAlt,
            separators: views.separatorsAlt,
            hasMailKeyword: signals.mailKeyword,
            effort: effort
        )
        detections += Extractors.platformSteering(
            base: views.base,
            alpha: views.alpha,
            compact: views.compact,
            alphaCompact: views.alphaCompact,
            hasContactIntent: signals.hasContactIntent,
            offPlatformIntent: signals.offPlatformIntent,
            effort: effort
        )
        detections += Extractors.handles(
            base: views.base,
            alpha: views.alpha,
            effort: effort,
            hasContactIntent: signals.hasContactIntent || signals.offPlatformIntent
        )
        detections += Extractors.leetDigitRuns(
            base: views.base, compact: views.compact, effort: effort
        )
        detections += Extractors.bareIdentifiers(
            base: views.base,
            wordTokenCount: Canonicalizer.tokenize(views.base).filter(\.isWord).count,
            hasContactIntent: signals.hasContactIntent,
            effort: effort
        )
        detections += Extractors.payments(
            base: views.base,
            raw: views.raw,
            hasPaymentKeyword: signals.paymentKeyword,
            effort: effort
        )
        detections += Extractors.payments(
            base: views.separators,
            raw: views.raw,
            hasPaymentKeyword: signals.paymentKeyword,
            effort: effort
        )
        if allowExpensiveTiers {
            detections += Extractors.encoded(raw: views.raw, base: views.base, effort: effort)

            detections += PositionalChannels.detect(
                original: analysed,
                base: views.base,
                raw: views.raw,
                effort: effort
            )
        }

        detections.removeAll { d in
            d.category == .socialHandle
                && Extractors.looksLikeBookingLocator(d.canonical)
                && !signals.hasContactIntent
                && !signals.offPlatformIntent
        }

        if detections.isEmpty {
            let acrosticDigits = Canonicalizer
                .expandNumberWords(views.acrostic)
                .filtering("digits-only") { $0.isNumber }
            detections += Extractors.phones(
                digitView: acrosticDigits, suppressed: false, effort: effort + 3
            )
        }

        var crossMessage = false
        if useConversationBuffer,
           detections.isEmpty || suppressedOnly,
           analysed.count <= Self.bufferAssemblyCharacterLimit {
            let previous = recentContext(actor).map {
                String($0.prefix(Self.bufferAssemblyCharacterLimit))
            }
            if !previous.isEmpty {
                let joined = (previous + [analysed]).joined(separator: " ")
                let joinedViews = canonicalizer.build(joined)
                let prefixLength = Array(previous.joined(separator: " ") + " ").count
                let currentLength = Array(analysed).count

                let analysedChars = Array(analysed)

                func localRange(_ r: Range<Int>, category: ModCategory) -> Range<Int> {
                    let contributing: [Int]
                    switch category {
                    case .phone:
                        contributing = views.digits.offsets + views.compactDigits.offsets
                    case .email, .externalURL, .socialHandle, .paymentHandle:
                        contributing = views.separators.offsets.filter { off in
                            guard off >= 0, off < currentLength, off < analysedChars.count
                            else { return false }
                            let ch = analysedChars[off]
                            return ch.isLetter || ch.isNumber || ch == "@" || ch == "."
                        }
                    default:
                        contributing = []
                    }

                    let inRange = contributing.filter { $0 >= 0 && $0 < currentLength }
                    if let lo = inRange.min(), let hi = inRange.max() {
                        return lo..<min(currentLength, hi + 1)
                    }

                    let lo = max(0, r.lowerBound - prefixLength)
                    let hi = min(currentLength, r.upperBound - prefixLength)
                    return lo < hi ? lo..<hi : 0..<0
                }

                var assembled: [Detection] = []

                assembled += Extractors.phones(
                    digitView: joinedViews.digitsMasked,
                    suppressed: false, effort: effort, spanMultiplier: 40
                )
                if assembled.isEmpty {
                    let maskedCompact = Canonicalizer
                        .expandNumberWords(
                            NumericContext.mask(joinedViews.base)
                                .filtering("compact") { $0.isLetter || $0.isNumber }
                        )
                        .filtering("digits-only") { $0.isNumber }
                    assembled += Extractors.phones(
                        digitView: maskedCompact,
                        suppressed: false, effort: effort, spanMultiplier: 40
                    )
                }

                assembled = assembled.filter { detection in
                    guard detection.category == .phone else { return true }
                    if detection.confidence >= 0.80 { return true }
                    let digits = String(detection.canonical.filter(\.isNumber))
                    return Extractors.isHighConfidencePhone(digits)
                        || Extractors.isHighConfidencePhone(String(digits.suffix(10)))
                }

                let window = previous + [analysed]

                if assembled.isEmpty {
                    let initials = String(window.compactMap {
                        $0.trimmingCharacters(in: .whitespaces).first
                    })
                    assembled += Extractors.phones(
                        digitView: canonicalizer.build(initials).digits,
                        suppressed: false, effort: effort, spanMultiplier: 40
                    )
                    if assembled.isEmpty, window.count >= 5 {
                        let letters = initials.lowercased().filter { $0.isLetter }
                        if letters.count >= 5 {
                            var hit: (String, Double, String)? = nil
                            for name in Lex.platformsStrong
                            where name.count >= 5 && letters.contains(name) {
                                hit = (name, 0.84, "Platform name spelled by message initials")
                                break
                            }
                            if hit == nil,
                               PositionalChannels.looksPronounceable(letters),
                               window.contains(where: { message in
                                   PositionalChannels.protocolHint(in: message.lowercased()) != nil
                               }) {
                                hit = (letters, 0.60, "Message initials spell \"\(letters)\"")
                            }
                            if let hit {
                                assembled.append(Detection(
                                    category: .socialHandle,
                                    range: 0..<max(1, currentLength),
                                    surface: "", canonical: hit.0, confidence: hit.1,
                                    transforms: ["conversation-buffer", "positional-channel"],
                                    effort: effort + 3, reason: hit.2
                                ))
                            }
                        }
                    }
                }

                if assembled.isEmpty, window.count >= 9 {
                    let wordCounts = window.map {
                        $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
                    }
                    let charCounts = window.map { $0.trimmingCharacters(in: .whitespaces).count }

                    for (label, counts) in [("word count", wordCounts), ("message length", charCounts)] {
                        guard counts.allSatisfy({ $0 >= 0 && $0 <= 10 }) else { continue }
                        let digits = counts.map { String($0 % 10) }.joined()
                        guard Extractors.isHighConfidencePhone(digits) else { continue }
                        assembled.append(Detection(
                            category: .phone,
                            range: 0..<max(1, currentLength),
                            surface: "", canonical: digits, confidence: 0.82,
                            transforms: ["conversation-buffer", "positional-channel"],
                            effort: effort + 5,
                            reason: "Phone number encoded in the \(label) of consecutive messages"
                        ))
                        break
                    }
                }

                if assembled.isEmpty {
                    let windowText = window.joined(separator: " ").lowercased()
                    let locatorContext = ["booking", "ref", "reference", "confirmation",
                                          "pnr", "locator", "itinerary"]
                        .contains { windowText.contains($0) }
                    let windowPlatform = Lex.platformsStrong.contains { windowText.contains($0) }
                        || windowText.contains("handle")
                    if !locatorContext {
                        assembled += Extractors.handles(
                            base: joinedViews.base,
                            alpha: joinedViews.alpha,
                            effort: effort,
                            hasContactIntent: windowPlatform
                        )
                    }
                    let windowMail = joined.lowercased().contains("mail")
                        || joined.lowercased().contains(" at ")
                        || joined.contains("@")
                    assembled += Extractors.emails(
                        base: joinedViews.base,
                        separators: joinedViews.separators,
                        hasMailKeyword: windowMail,
                        effort: effort
                    )
                    if assembled.isEmpty {
                        assembled += Extractors.spelledEmails(in: joined, effort: effort)
                        if assembled.isEmpty {
                            assembled += Extractors.spelledURLs(in: joined, effort: effort)
                        }
                    }
                }

                if assembled.isEmpty {
                    let fragments = window
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { $0.count <= 8 && !$0.contains(" ") && $0.allSatisfy { $0.isLetter } }
                    if fragments.count >= 3 {
                        let glued = fragments.joined()
                        let windowText = window.joined(separator: " ").lowercased()
                        let windowPlatform = Lex.platformsStrong.contains { windowText.contains($0) }
                            || windowText.contains("handle")
                        let locatorContext = ["booking", "ref", "reference", "confirmation",
                                              "pnr", "locator", "itinerary"]
                            .contains { windowText.contains($0) }
                        if glued.count >= 8, windowPlatform, !locatorContext,
                           Lex.fuzzyPlatform(glued) == nil,
                           !Lex.platformsStrong.contains(glued) {
                            assembled.append(Detection(
                                category: .socialHandle,
                                range: 0..<max(1, currentLength),
                                surface: "", canonical: glued,
                                confidence: 0.78, transforms: ["conversation-buffer"],
                                effort: effort,
                                reason: "Identifier assembled from consecutive short messages"
                            ))
                        }
                    }
                }

                if let first = assembled.first {
                    let canon = first.canonical.lowercased()
                    let bogusPlatform = Lex.platformsStrong.contains(canon)
                        || Lex.platformsWeak.contains(canon)
                    let windowText = window.joined(separator: " ").lowercased()
                    let windowPlatform = Lex.platformsStrong.contains { windowText.contains($0) }
                        || windowText.contains("handle")
                    let locatorWithoutChannel = first.category == .socialHandle
                        && Extractors.looksLikeBookingLocator(first.canonical)
                        && !windowPlatform
                    let isPositionalChannel = first.transforms.contains("positional-channel")
                    if (!bogusPlatform || isPositionalChannel), !locatorWithoutChannel {
                        crossMessage = true
                        buffers.consume(actor: actor)
                        detections.append(Detection(
                            category: first.category,
                            range: localRange(first.range, category: first.category),
                            surface: "",
                            canonical: first.canonical,
                            confidence: max(first.confidence, 0.88),
                            transforms: first.transforms + ["conversation-buffer"],
                            effort: effort + 4,
                            reason: "\(first.category.display) assembled across recent messages"
                        ))
                    }
                }
            }
        }

        var usedRetrieval = false
        var retrievalMargin: Double = 0
        var retrievalSimilarity: Double = 0
        var retrievalEscalation: SemanticRetriever.Thresholds? = nil
        if deps.tier2Enabled, detections.filter({ $0.category.isContactExfiltration }).isEmpty {
            if let result = deps.retriever.retrieve(analysed) {
                retrievalMargin = result.margin
                retrievalSimilarity = result.similarity
                retrievalEscalation = result.space.escalation
            }
            if let semantic = deps.retriever.detect(
                analysed,
                textLength: Array(analysed).count,
                effort: effort
            ) {
                detections.append(semantic)
                usedRetrieval = true
            }
        }

        detections = detections.filter { detection in
            guard detection.category == .externalURL else { return true }
            guard let host = Self.host(ofCandidate: detection.canonical) else { return true }
            return !SafetyRules.isPlatformOwned(host: host)
        }

        detections = dedupe(detections, textLength: Array(analysed).count)

        detections = detections.map { d in
            Detection(
                category: d.category, range: d.range, surface: d.surface,
                canonical: d.canonical, confidence: d.confidence,
                transforms: d.transforms,
                effort: Canonicalizer.effort(for: d.transforms),
                reason: d.reason
            )
        }
        let contactEffort = detections
            .filter { $0.category.isContactExfiltration }
            .map(\.effort).max() ?? 0

        let safety = safetyPass(
            original: original,
            analysed: analysed,
            views: views,
            singlePass: allowExpensiveTiers,
            deps: deps
        )
        var safetyFindings = safety.findings
        let usedSafetyRetrieval = safety.usedRetrieval
        let safetyInnocentSimilarity = safety.innocentSimilarity
        let safetySimilarity = safety.similarity

        let addressesPersonForClassifier = EscalationAnalyser.addressesPerson(views.alpha)
            || EscalationAnalyser.addressesPersonNativeScript(analysed)
        let bargain = LeverTaxonomy.bargainSignals(in: analysed)
        // Translates raw sigmoid scores into categorical safety findings based on the calibration profile
        var classification = deps.safetyClassifier.classify(SafetyClassifierInput(
            text: analysed,
            deterministicFindings: safety.findings,
            safetySimilarity: safetySimilarity,
            innocentSimilarity: safetyInnocentSimilarity,
            addressesPerson: addressesPersonForClassifier,
            conditionalDemand: EscalationAnalyser.conditionalDemand(views.base.text)
                || EscalationAnalyser.nativeConditionalDemand(analysed)
                || bargain.isBargain,
            propertyDirected: Self.mentionsProperty(views.alpha),
            reviewBargainScore: bargain.coercionPrior
        ))
        if bargain.coercionPrior > 0 {
            classification.raise(.coercion, to: bargain.coercionPrior)
        }
        if bargain.coercionPrior >= 0.55 {
            classification.set(.legitimateComplaint, 0)
        }
        let layer3 = deps.safetyClassifier.calibration.apply(
            classification, textLength: Array(analysed).count
        )
        if let finding = layer3.finding,
           !safetyFindings.contains(where: { $0.category == finding.category }) {
            safetyFindings.append(finding)
        }

        if signals.offPlatformIntent, let phrase = signals.offPlatformPhrase {
            let baseText = views.base.text
            if let r = baseText.range(of: phrase) {
                let s = baseText.distance(from: baseText.startIndex, to: r.lowerBound)
                let e = baseText.distance(from: baseText.startIndex, to: r.upperBound)
                if let orig = views.base.originalRange(s, e) {
                    safetyFindings.append(SafetyRules.Finding(
                        category: .scam, confidence: 0.80, phrase: phrase, range: orig
                    ))
                }
            }
        }

        let contactDetections = detections.filter { $0.category.isContactExfiltration }
        let scoring = scorer.score(Scorer.Input(
            detections: contactDetections,
            signals: signals,
            obfuscationEffort: contactEffort,
            suppressedOnly: suppressedOnly,
            crossMessageAssembled: crossMessage,
            priorViolations: actor.priorViolations
        ))

        let decision = Policy.decide(
            score: scoring.score,
            contactDetections: contactDetections,
            safetyFindings: safetyFindings,
            actor: actor,
            advisoryOnly: advisoryOnly,
            config: policy
        )

        let effectiveDetections: [Detection]
        if decision.action == .allow {
            effectiveDetections = []
        } else if scoring.score >= Policy.thresholds(for: actor, config: policy).mask {
            effectiveDetections = contactDetections + safetyFindings.map {
                Detection(
                    category: $0.category, range: $0.range, surface: "",
                    canonical: $0.phrase, confidence: $0.confidence,
                    transforms: [], effort: 0, reason: "Safety rule: \($0.category.display)"
                )
            }
        } else {
            effectiveDetections = safetyFindings.map {
                Detection(
                    category: $0.category, range: $0.range, surface: "",
                    canonical: $0.phrase, confidence: $0.confidence,
                    transforms: [], effort: 0, reason: "Safety rule: \($0.category.display)"
                )
            }
        }

        let withSurfaces = attachSurfaces(effectiveDetections, original: original)
        let allWithSurfaces = attachSurfaces(
            detections + safetyFindings.map {
                Detection(
                    category: $0.category, range: $0.range, surface: "",
                    canonical: $0.phrase, confidence: $0.confidence,
                    transforms: [], effort: 0, reason: "Safety rule: \($0.category.display)"
                )
            },
            original: original
        )

        var reasonCodes = decision.reasonCodes
        if crossMessage { reasonCodes.append("CROSS_MESSAGE_ASSEMBLY") }
        if suppressedOnly { reasonCodes.append("NUMERIC_CONTEXT_SUPPRESSED") }
        if !contextResult.firedRules.isEmpty {
            reasonCodes.append("NUMCTX(\(contextResult.firedRules.prefix(3).joined(separator: ",")))")
        }

        if usedRetrieval { reasonCodes.append("TIER2_RETRIEVAL") }
        if usedSafetyRetrieval { reasonCodes.append("TIER2_SAFETY_RETRIEVAL") }
        reasonCodes.append(contentsOf: layer3.reasonCodes)
        if truncated { reasonCodes.append("INPUT_TRUNCATED(\(fullLength)→\(Self.maxAnalysedCharacters))") }
        if !allowExpensiveTiers { reasonCodes.append("EXPENSIVE_TIERS_SKIPPED") }
        if safety.chunks > 1 { reasonCodes.append("SAFETY_CHUNKED_SCAN(\(safety.chunks))") }
        if safety.truncatedForSafety { reasonCodes.append("SAFETY_SCAN_TRUNCATED") }

        let tier: Int
        if usedRetrieval {
            tier = 2
        } else if decision.action == .allow && detections.isEmpty {
            tier = 1
        } else {
            tier = crossMessage ? 2 : 1
        }
        let escalation = EscalationAnalyser.analyse(
            original: analysed,
            views: views,
            detections: effectiveDetections,
            suppressedOnly: suppressedOnly,
            signals: signals,
            allowExpensiveTiers: allowExpensiveTiers,
            retrievalMargin: retrievalMargin,
            retrievalSimilarity: retrievalSimilarity,
            escalationThresholds: retrievalEscalation ?? deps.retriever.escalationThresholds,
            safetyInnocentSimilarity: safetyInnocentSimilarity,
            safetySimilarity: safetySimilarity,
            classifierRouted: layer3.shouldRoute
        )
        if let code = escalation.reasonCode { reasonCodes.append(code) }

        var finalAction = decision.action
        var finalScore = scoring.score
        var reportedDetections = allWithSurfaces
        var manipulationRange: Range<Int>? = nil

        if escalation.suspicions.contains(.promptManipulation) {
            let length = max(1, Array(original).count)
            reportedDetections.append(Detection(
                category: .systemManipulation,
                range: 0..<length,
                surface: original,
                canonical: "moderation tampering",
                confidence: 0.90,
                transforms: views.base.transforms,
                effort: contactEffort + 4,
                reason: "Contains text directed at the moderation system rather than at the recipient"
            ))
            reasonCodes.append("SYSTEM_MANIPULATION")
            manipulationRange = 0..<length
            if finalAction.rank < ModAction.block.rank, !advisoryOnly {
                finalAction = .block
            }
            finalScore = max(finalScore, 0.75)
        }

        var learnedAbuseSignal = false
        if !advisoryOnly, let router = abuseRouter {
            let routerScore = router.score(original)
            // Triggers escalation if the lightweight n-gram router flags a character-level structural anomaly
            if routerScore >= router.threshold {
                learnedAbuseSignal = true
                reasonCodes.append(String(format: "LEARNED_ABUSE(%.2f)", routerScore))
            }
        }

        var behaviouralSuspicion = false
        var behaviouralRisk = ActorRisk()
        if !advisoryOnly {
            let safetySignal = classification.strongestViolation?.score ?? 0
            let actedOnSafety = !safetyFindings.isEmpty
                && finalAction != .allow && finalAction != .hint
            // Prevents lawful complaints (like threatening a 1-star review) from incrementing behavioural abuse counters
            let lawfulRemedyOnly = LeverTaxonomy.classify(analysed) == .lawful
            let patternEligible = layer3.shouldRoute
                && classification.legitimateComplaint < deps.safetyClassifier.calibration.complaintVeto
                && !lawfulRemedyOnly
            deps.actorSignals.observe(
                sender: actor.senderID,
                conversation: actor.conversationID,
                safetyScore: safetySignal,
                routedForSafety: patternEligible,
                acted: actedOnSafety
            )
            behaviouralRisk = deps.actorSignals.risk(
                for: actor.senderID, conversation: actor.conversationID
            )

            if behaviouralRisk.escalating, patternEligible {
                behaviouralSuspicion = true
                reasonCodes.append(
                    "BEHAVIOUR_PATTERN(\(behaviouralRisk.subThresholdSafetyHits) sub-threshold)")
                if finalAction.rank < ModAction.block.rank, !advisoryOnly {
                    finalAction = .block
                    finalScore = max(finalScore, 0.65)
                }
            }
            if behaviouralRisk.receivedReports > 0 {
                reasonCodes.append("ACTOR_REPORTED(\(behaviouralRisk.receivedReports))")
            }
            if behaviouralRisk.isElevated {
                reasonCodes.append(
                    String(format: "ACTOR_RISK(%.2f)", behaviouralRisk.composite))
            }
        }

        let escalateSuspicions = escalation.suspicions.filter { $0 != .personDirectedAnomaly }
        let escalate = deps.abstainBand.contains(scoring.score)
            || !escalateSuspicions.isEmpty
            || behaviouralSuspicion || learnedAbuseSignal
        if escalate { reasonCodes.append("TIER3_ESCALATION_CANDIDATE") }

        var provisionalHold = false
        if policy.provisionalHoldEnabled, escalate, !advisoryOnly, !finalAction.withholdsMessage {
            let critical = policy.criticalCategories
            let classifierCritical: Bool = {
                guard let (head, score) = classification.strongestViolation,
                      let category = head.category,
                      critical.contains(category)
                else { return false }
                return deps.safetyClassifier.calibration.band(for: head, score: score) != .allow
            }()
            let deterministicCritical = safetyFindings.contains {
                critical.contains($0.category)
            }
            if classifierCritical || deterministicCritical {
                provisionalHold = true
                reasonCodes.append("PROVISIONAL_HOLD")

                if !deps.tier3Available, finalAction.rank < ModAction.block.rank {
                    finalAction = .block
                    finalScore = max(finalScore, 0.65)
                    reasonCodes.append("SAFETY_FAIL_CLOSED")
                }
            }
        }

        return Verdict(
            action: finalAction,
            score: finalScore,
            detections: reportedDetections,
            categories: Set(reportedDetections.map(\.category)),
            reasonCodes: reasonCodes,
            tierReached: tier,
            latencyMs: elapsedMs(since: started),
            features: scoring.contributions,
            threshold: decision.threshold,
            maskedText: Policy.redact(
                original,
                detections: withSurfaces + (manipulationRange.map {
                    [Detection(
                        category: .systemManipulation, range: $0, surface: "",
                        canonical: "moderation tampering", confidence: 0.90,
                        transforms: [], effort: 0,
                        reason: "Moderation tampering"
                    )]
                } ?? [])
            ),
            redactedRanges: (withSurfaces.map(\.range) + (manipulationRange.map { [$0] } ?? []))
                .sorted { $0.lowerBound < $1.lowerBound },
            transformsApplied: transforms,
            obfuscationEffort: contactEffort,
            suspicions: escalation.suspicions
                + (behaviouralSuspicion ? [.escalatingPattern] : [])
                + (learnedAbuseSignal ? [.learnedAbuse] : []),
            carriers: escalation.carriers,
            policyVersion: policy.version,
            provisionalHold: provisionalHold
        )
    }

    func hint(_ text: String, actor: ActorContext = .default) -> Verdict {
        evaluate(text, actor: actor, advisoryOnly: true, useConversationBuffer: false)
    }

    func shouldEscalate(_ verdict: Verdict) -> Bool {
        if !verdict.suspicions.isEmpty { return true }
        return abstainBand.contains(verdict.score)
    }

    func escalate(
        verdict: Verdict,
        message: String,
        actor: ActorContext = .default
    ) async -> (verdict: Verdict, judgement: JudgeVerdict)? {
        guard shouldEscalate(verdict) else { return nil }

        let window = recentContext(actor) + [message]
        let request = JudgeRequest(
            window: window,
            priorScore: verdict.score,
            priorFindings: verdict.detections.map { "\($0.category.rawValue): \($0.canonical)" },
            bookingStage: actor.stage,
            trust: actor.trust,
            suspicions: verdict.suspicions,
            carriers: verdict.carriers
        )

        let judgement = await judge.judge(request)

        let revised = applyJudgement(judgement, to: verdict, message: message, actor: actor)
        return (revised, judgement)
    }

    func judgeRequest(for verdict: Verdict, message: String, actor: ActorContext) -> JudgeRequest {
        JudgeRequest(
            window: recentContext(actor) + [message],
            priorScore: verdict.score,
            priorFindings: verdict.detections.map { "\($0.category.rawValue): \($0.canonical)" },
            bookingStage: actor.stage,
            trust: actor.trust,
            suspicions: verdict.suspicions,
            carriers: verdict.carriers
        )
    }

    func applyJudgement(
        _ judgement: JudgeVerdict,
        to verdict: Verdict,
        message: String,
        actor: ActorContext
    ) -> Verdict {
        // Enforces safety fail-closed guarantees when the LLM adjudicator fails to return a conclusive judgement
        if judgement.decision == .abstain {
            let safetyShaped = verdict.suspicions.contains(.learnedAbuse) && verdict.score > 0.20
            let tier2Routed = verdict.reasonCodes.contains(where: { $0.hasPrefix("LAYER3_ROUTE") })
            guard safetyShaped || tier2Routed, verdict.action == .allow || verdict.action == .hint else {
                return verdict
            }
            var reasons = verdict.reasonCodes
            reasons.append("SAFETY_FAIL_CLOSED")
            var held = Verdict(
                action: .block, score: verdict.score, detections: verdict.detections,
                categories: verdict.categories, reasonCodes: reasons, tierReached: 3,
                latencyMs: verdict.latencyMs + judgement.latencyMs,
                features: verdict.features, threshold: verdict.threshold,
                maskedText: "", redactedRanges: [],
                transformsApplied: verdict.transformsApplied,
                obfuscationEffort: verdict.obfuscationEffort,
                policyVersion: verdict.policyVersion
            )
            held.judgement = JudgementRecord(
                decision: judgement.decision.rawValue,
                confidence: judgement.confidence,
                rationale: judgement.rationale,
                source: judgement.source,
                latencyMs: judgement.latencyMs,
                priorAction: verdict.action,
                priorScore: verdict.score
            )
            held.suspicions = verdict.suspicions
            held.carriers = verdict.carriers
            return held
        }
        var revised = revise(verdict, with: judgement, message: message, actor: actor)
        revised.judgement = JudgementRecord(
            decision: judgement.decision.rawValue,
            confidence: judgement.confidence,
            rationale: judgement.rationale,
            source: judgement.source,
            latencyMs: judgement.latencyMs,
            priorAction: verdict.action,
            priorScore: verdict.score
        )
        revised.suspicions = verdict.suspicions
        revised.carriers = verdict.carriers
        return revised
    }

    private func revise(
        _ verdict: Verdict,
        with judgement: JudgeVerdict,
        message: String,
        actor: ActorContext
    ) -> Verdict {
        var detections = verdict.detections
        var reasons = verdict.reasonCodes
        let length = max(1, Array(message).count)

        if judgement.decision == .safetyViolation {
            let category = judgement.safetyCategory ?? .coercion
            let finding = SafetyRules.Finding(
                category: category,
                confidence: max(judgement.confidence, 0.80),
                phrase: judgement.rationale,
                range: 0..<length
            )
            let decision = Policy.decide(
                score: verdict.score,
                contactDetections: detections.filter { $0.category.isContactExfiltration },
                safetyFindings: [finding],
                actor: actor,
                advisoryOnly: false
            )
            reasons.append("TIER3_SAFETY")
            reasons.append(contentsOf: decision.reasonCodes.filter { !reasons.contains($0) })
            detections.append(Detection(
                category: category,
                range: 0..<length,
                surface: "",
                canonical: category.rawValue,
                confidence: finding.confidence,
                transforms: ["tier3-safety"],
                effort: verdict.obfuscationEffort,
                reason: "\(judgement.rationale) [\(judgement.source)]"
            ))
            return Verdict(
                action: decision.action,
                score: verdict.score,
                detections: detections,
                categories: Set(detections.map(\.category)),
                reasonCodes: reasons,
                tierReached: 3,
                latencyMs: verdict.latencyMs + judgement.latencyMs,
                features: verdict.features, threshold: verdict.threshold,
                maskedText: decision.action.withholdsMessage
                    ? "" : Policy.redact(message, detections: detections),
                redactedRanges: [],
                transformsApplied: verdict.transformsApplied,
                obfuscationEffort: verdict.obfuscationEffort,
                policyVersion: verdict.policyVersion
            )
        }

        if judgement.decision == .benign {
            let hasHardEvidence = detections.contains {
                ($0.category.isContactExfiltration && $0.confidence >= 0.85
                    && !$0.transforms.contains("semantic-retrieval"))
                || ($0.category == .coercion && $0.confidence >= 0.80)
            }
            guard !hasHardEvidence else { return verdict }

            guard !verdict.suspicions.contains(.promptManipulation) else {
                var reasons = verdict.reasonCodes
                reasons.append("TIER3_CLEARANCE_REFUSED_INJECTION")
                var held = verdict
                held.reasonCodes = reasons
                return held
            }

            reasons.append("TIER3_CLEARED")
            return Verdict(
                action: .allow, score: min(verdict.score, 0.15), detections: [],
                categories: [], reasonCodes: reasons, tierReached: 3,
                latencyMs: verdict.latencyMs + judgement.latencyMs,
                features: verdict.features, threshold: verdict.threshold,
                maskedText: message, redactedRanges: [],
                transformsApplied: verdict.transformsApplied,
                obfuscationEffort: verdict.obfuscationEffort,
                policyVersion: verdict.policyVersion
            )
        }

        let coincidenceProne = verdict.suspicions == [.positionalCarrier]
            && !detections.contains { $0.category.isContactExfiltration && $0.confidence >= 0.85 }
        if coincidenceProne, judgement.confidence < 0.90 {
            var held = verdict
            reasons.append("TIER3_UNCORROBORATED_CARRIER")
            held.reasonCodes = reasons
            return held
        }

        let intent = judgement.intent ?? .referentialContact
        detections.append(Detection(
            category: intent.category,
            range: 0..<length,
            surface: message,
            canonical: intent.display,
            confidence: min(max(judgement.confidence, 0.5), 0.97),
            transforms: ["semantic-judge"],
            effort: verdict.obfuscationEffort,
            reason: "\(judgement.rationale) [\(judgement.source)]"
        ))
        reasons.append("TIER3_EXFILTRATION")

        let blended = max(verdict.score, 0.45 + judgement.confidence * 0.5)
        let action: ModAction = blended >= Policy.thresholds(for: actor).withhold ? .warn : .mask

        return Verdict(
            action: action, score: min(blended, 0.99), detections: detections,
            categories: Set(detections.map(\.category)), reasonCodes: reasons,
            tierReached: 3,
            latencyMs: verdict.latencyMs + judgement.latencyMs,
            features: verdict.features, threshold: verdict.threshold,
            maskedText: Policy.redact(message, detections: detections),
            redactedRanges: detections.map(\.range),
            transformsApplied: verdict.transformsApplied,
            obfuscationEffort: verdict.obfuscationEffort
        )
    }

    struct SafetyPass {
        var findings: [SafetyRules.Finding] = []
        var usedRetrieval = false
        var innocentSimilarity = -1.0
        var similarity = -1.0
        var chunks = 0
        var truncatedForSafety = false
    }

    private func safetyPass(
        original: String,
        analysed: String,
        views: Canonicalizer.Views,
        singlePass: Bool,
        deps: Dependencies
    ) -> SafetyPass {
        var out = SafetyPass()

        func absorbRetrieval(_ text: String) {
            guard deps.tier2Enabled else { return }
            guard let result = deps.retriever.safetyRetrieval(text) else { return }
            out.innocentSimilarity = out.innocentSimilarity < 0
                ? result.negativeSimilarity
                : min(out.innocentSimilarity, result.negativeSimilarity)
            out.similarity = max(out.similarity, result.similarity)

            guard let semantic = deps.retriever.safetyFinding(
                from: result, textLength: Array(text).count
            ) else { return }
            guard !out.findings.contains(where: { $0.category == semantic.category }),
                  SafetyRules.semanticFindingHolds(semantic, text: text.lowercased())
            else { return }
            out.findings.append(semantic)
            out.usedRetrieval = true
        }

        let wholeDeterministic = SafetyRules.evaluate(
            base: views.base, alpha: views.alpha, alphaCompact: views.alphaCompact,
            skeleton: views.hinglishSkeleton,
            original: analysed
        )
        out.findings = wholeDeterministic
        out.chunks = 1

        if singlePass {
            absorbRetrieval(analysed)
            return out
        }

        let chars = Array(original)
        let scanEnd = min(chars.count, Self.safetyScanCharacterLimit)
        out.truncatedForSafety = chars.count > scanEnd

        if chars.count > Self.maxAnalysedCharacters {
            let stride = max(Self.safetyChunkSize - Self.safetyChunkOverlap, 1)
            var start = max(0, Self.maxAnalysedCharacters - Self.safetyChunkOverlap)
            while start < scanEnd, out.chunks < Self.safetyMaxChunks {
                let end = min(start + Self.safetyChunkSize, scanEnd)
                let chunk = String(chars[start..<end])
                out.chunks += 1

                let chunkViews = canonicalizer.build(chunk)
                let chunkFindings = SafetyRules.evaluate(
                    base: chunkViews.base, alpha: chunkViews.alpha,
                    alphaCompact: chunkViews.alphaCompact,
                    skeleton: chunkViews.hinglishSkeleton, original: chunk
                )
                for finding in chunkFindings {
                    guard !out.findings.contains(where: { $0.category == finding.category })
                    else { continue }
                    out.findings.append(SafetyRules.Finding(
                        category: finding.category,
                        confidence: finding.confidence,
                        phrase: finding.phrase,
                        range: (finding.range.lowerBound + start)..<(finding.range.upperBound + start)
                    ))
                }

                if end == scanEnd { break }
                start += stride
            }
        }

        var probeStart = 0
        var probes = 0
        while probeStart < scanEnd, probes < Self.safetyMaxChunks {
            let end = min(probeStart + Self.safetyChunkSize, scanEnd)
            absorbRetrieval(String(chars[probeStart..<end]))
            probes += 1
            if end == scanEnd { break }
            probeStart += Self.safetyChunkSize
        }
        return out
    }

    static func mentionsProperty(_ alpha: CharView) -> Bool {
        for token in Canonicalizer.tokenize(alpha) where token.isWord {
            if Lex.propertyTargets.contains(token.text) { return true }
        }
        return false
    }

    static func host(ofCandidate candidate: String) -> String? {
        var s = candidate.lowercased().trimmingCharacters(in: .whitespaces)
        if let schemeEnd = s.range(of: "://")?.upperBound { s = String(s[schemeEnd...]) }
        let authority = s.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.isEmpty else { return nil }
        let hostPart = authority.split(separator: "@").last ?? authority
        return hostPart.split(separator: ":").first.map(String.init)
    }

    private func elapsedMs(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }

    private func expandToWordBoundaries(_ range: Range<Int>, in chars: [Character]) -> Range<Int> {
        guard !chars.isEmpty else { return range }
        guard !range.isEmpty else { return range }
        var lo = max(0, min(range.lowerBound, chars.count))
        var hi = max(lo, min(range.upperBound, chars.count))

        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

        while lo > 0, isWordChar(chars[lo - 1]) { lo -= 1 }
        while hi < chars.count, isWordChar(chars[hi]) { hi += 1 }
        return lo..<hi
    }

    private func expandOverAdjacentNumerics(_ range: Range<Int>, in chars: [Character]) -> Range<Int> {
        guard !range.isEmpty, !chars.isEmpty else { return range }

        func isNumericToken(_ token: String) -> Bool {
            guard !token.isEmpty else { return false }
            if token.allSatisfy(\.isNumber) { return true }
            return Lex.allNumberWords[token.lowercased()] != nil
        }

        func token(from index: Int, forward: Bool) -> (String, Int)? {
            var i = index
            func isSep(_ c: Character) -> Bool { !c.isLetter && !c.isNumber }
            while i >= 0, i < chars.count, isSep(chars[i]) { i += forward ? 1 : -1 }
            guard i >= 0, i < chars.count else { return nil }
            var lo = i, hi = i
            while lo > 0, !isSep(chars[lo - 1]) { lo -= 1 }
            while hi < chars.count - 1, !isSep(chars[hi + 1]) { hi += 1 }
            return (String(chars[lo...hi]), forward ? hi + 1 : lo)
        }

        var lower = range.lowerBound
        var upper = range.upperBound

        while upper < chars.count, let (text, end) = token(from: upper, forward: true),
              isNumericToken(text) {
            upper = min(end, chars.count)
        }
        while lower > 0, let (text, start) = token(from: lower - 1, forward: false),
              isNumericToken(text) {
            lower = max(0, start)
        }
        return lower..<upper
    }

    private func attachSurfaces(_ detections: [Detection], original: String) -> [Detection] {
        let chars = Array(original)
        return detections.map { d in
            var expanded = expandToWordBoundaries(d.range, in: chars)
            if d.category == .phone {
                expanded = expandOverAdjacentNumerics(expanded, in: chars)
            }
            let lo = expanded.lowerBound
            let hi = expanded.upperBound
            return Detection(
                category: d.category,
                range: lo..<hi,
                surface: String(chars[lo..<hi]),
                canonical: d.canonical,
                confidence: d.confidence,
                transforms: d.transforms,
                effort: d.effort,
                reason: d.reason
            )
        }
    }

    private func dedupe(_ detections: [Detection], textLength: Int) -> [Detection] {
        var best: [String: Detection] = [:]
        for d in detections {
            let lo = max(0, min(d.range.lowerBound, textLength))
            let hi = max(lo, min(d.range.upperBound, textLength))
            guard hi > lo else { continue }
            let key = "\(d.category.rawValue)|\(lo)|\(hi)"
            if let existing = best[key], existing.confidence >= d.confidence { continue }
            best[key] = d
        }
        let sorted = best.values.sorted { $0.confidence > $1.confidence }
        var kept: [Detection] = []
        for d in sorted {
            let swallowed = kept.contains {
                $0.category == d.category
                    && $0.range.lowerBound <= d.range.lowerBound
                    && $0.range.upperBound >= d.range.upperBound
            }
            if !swallowed { kept.append(d) }
        }
        return kept.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
