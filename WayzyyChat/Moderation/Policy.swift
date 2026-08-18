// Versioned policy configuration: thresholds, trust and stage offsets, the enforcement ladder and safety overrides.

import Foundation

struct Policy {

    struct Thresholds: Codable, Equatable {
        var hint: Double
        var mask: Double
        var withhold: Double

        static let base = Thresholds(hint: 0.22, mask: 0.38, withhold: 0.60)
    }

    struct Configuration: Codable, Equatable {
        var version: String

        var baseThresholds: Thresholds

        var trustOffsets: [String: Double]
        var stageOffsets: [String: Double]

        var violationPenalty: Double
        var maxPriorsCounted: Double

        var repeatOffenderBlockAt: Int
        var repeatOffenderWarnAt: Int

        var explicitIdentifierFloor: Double

        var safetyActions: [String: String]

        var scamBlockConfidence: Double

        var provisionalHoldEnabled: Bool
        var criticalSeverity: [String]

        static let v1 = Configuration(
            version: "2026-08-18.v2",
            baseThresholds: .base,
            trustOffsets: [:],
            stageOffsets: [:],
            violationPenalty: 0.05,
            maxPriorsCounted: 3.0,
            repeatOffenderBlockAt: 3,
            repeatOffenderWarnAt: 2,
            explicitIdentifierFloor: 0.65,
            safetyActions: [
                ModCategory.threat.rawValue:     ModAction.block.rawValue,
                ModCategory.sexual.rawValue:     ModAction.block.rawValue,
                // No human review queue exists. Coercion and discrimination used to map to
                // `review`, which held the message forever. They withhold as `block`.
                ModCategory.coercion.rawValue:   ModAction.block.rawValue,
                ModCategory.harassment.rawValue: ModAction.warn.rawValue,
                ModCategory.discrimination.rawValue: ModAction.block.rawValue,
            ],
            scamBlockConfidence: 0.95,
            provisionalHoldEnabled: true,
            criticalSeverity: [ModCategory.threat.rawValue, ModCategory.sexual.rawValue]
        )

        static func decoded(from data: Data) throws -> Configuration {
            try JSONDecoder().decode(Configuration.self, from: data)
        }

        func encoded() throws -> Data {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try e.encode(self)
        }

        func action(for category: ModCategory) -> ModAction? {
            safetyActions[category.rawValue].flatMap(ModAction.init(rawValue:))
        }

        var criticalCategories: Set<ModCategory> {
            Set(criticalSeverity.compactMap(ModCategory.init(rawValue:)))
        }
    }

    // The active configuration is behind a lock.
    //
    // `Configuration` is a multi-field struct, so an unsynchronised static var is not merely
    // stale-prone under concurrency — a read racing a write observes a torn value and can
    // crash outright. Verified: concurrent evaluation with rollout in flight segfaulted
    // before this lock existed.
    //
    // Reads are short and uncontended in the normal case, because each evaluation takes
    // exactly one snapshot at request entry rather than reading repeatedly.
    private static let configLock = NSLock()
    private static var _current: Configuration = .v1

    static var current: Configuration {
        get {
            configLock.lock()
            defer { configLock.unlock() }
            return _current
        }
        set {
            configLock.lock()
            _current = newValue
            configLock.unlock()
        }
    }

    static var provisionalHoldEnabled: Bool {
        get { current.provisionalHoldEnabled }
        set {
            configLock.lock()
            _current.provisionalHoldEnabled = newValue
            configLock.unlock()
        }
    }

    static var criticalSeverity: Set<ModCategory> { current.criticalCategories }

    struct Decision {
        let action: ModAction
        let threshold: Double
        let reasonCodes: [String]
    }

    /// Take one immutable copy of the active configuration.
    ///
    /// A verdict must be decided against a single policy version. Reading the global
    /// repeatedly during one evaluation means a config change mid-request could apply a
    /// threshold from one version and an action table from another, producing a verdict that
    /// matches no policy that ever existed — and stamping it with whichever version was read
    /// last. Callers take a snapshot once and pass it down.
    ///
    /// `Configuration` is a value type, so the snapshot cannot be mutated behind the caller.
    static func snapshot() -> Configuration { current }

    static func thresholds(for actor: ActorContext,
                           config: Configuration = Policy.current) -> Thresholds {
        var t = config.baseThresholds
        let trust = config.trustOffsets[actor.trust.rawValue] ?? actor.trust.thresholdOffset
        let stage = config.stageOffsets[actor.stage.rawValue] ?? actor.stage.thresholdOffset
        let offset = trust + stage
        let violationPenalty =
            min(Double(actor.priorViolations), config.maxPriorsCounted) * config.violationPenalty

        t.hint = clamp(t.hint + offset - violationPenalty)
        t.mask = clamp(t.mask + offset - violationPenalty)
        t.withhold = clamp(t.withhold + offset - violationPenalty)
        return t
    }

    static func decide(
        score: Double,
        contactDetections: [Detection],
        safetyFindings: [SafetyRules.Finding],
        actor: ActorContext,
        advisoryOnly: Bool,
        config: Configuration = Policy.current
    ) -> Decision {
        let t = thresholds(for: actor, config: config)
        var reasons: [String] = []
        var action: ModAction = .allow

        if !contactDetections.isEmpty {
            if score >= t.withhold {
                if actor.priorViolations >= config.repeatOffenderBlockAt {
                    action = .block
                    reasons.append("CONTACT_EXFIL_REPEAT_OFFENDER")
                } else if actor.priorViolations >= config.repeatOffenderWarnAt {
                    action = .warn
                    reasons.append("CONTACT_EXFIL_REPEATED")
                } else {
                    action = .mask
                    reasons.append("CONTACT_EXFIL_HIGH")
                }
            } else if score >= t.mask {
                action = .mask
                reasons.append("CONTACT_EXFIL_MASK")
            } else if score >= t.hint {
                action = .hint
                reasons.append("CONTACT_EXFIL_LOW")
            } else {
                reasons.append("CONTACT_EXFIL_BELOW_THRESHOLD")
            }

            let literalIdentifier: Set<ModCategory> = [
                .phone, .email, .socialHandle, .paymentHandle, .cryptoAddress, .bankDetails,
            ]
            let hasExplicitIdentifier = contactDetections.contains { d in
                literalIdentifier.contains(d.category)
                    && d.confidence >= config.explicitIdentifierFloor
                    && !d.transforms.contains("semantic-retrieval")
                    && !d.transforms.contains("semantic-judge")
            }
            if hasExplicitIdentifier, action.rank < ModAction.mask.rank {
                action = .mask
                reasons.append("CONTACT_EXPLICIT_IDENTIFIER_FLOOR")
            }

            let cats = Set(contactDetections.map(\.category))
            for c in cats.sorted(by: { $0.rawValue < $1.rawValue }) {
                reasons.append("CAT_\(c.rawValue.uppercased())")
            }
            if contactDetections.contains(where: { $0.effort >= 5 }) {
                reasons.append("HIGH_OBFUSCATION_EFFORT")
            }
        }

        for finding in safetyFindings {
            switch finding.category {
            case .selfHarm:
                reasons.append("SAFETY_SELF_HARM_SUPPORT")

            case .scam:
                if finding.confidence >= config.scamBlockConfidence {
                    action = maxAction(action, .block)
                    reasons.append("SAFETY_PHISHING")
                } else {
                    action = maxAction(action, .block)
                    reasons.append("SAFETY_SCAM")
                }

            default:
                guard let mapped = config.action(for: finding.category) else { break }
                action = maxAction(action, mapped)
                reasons.append("SAFETY_\(finding.category.rawValue.uppercased())")
            }
        }

        if advisoryOnly, action.rank > ModAction.hint.rank {
            action = .hint
        }

        if action == .allow, reasons.isEmpty {
            reasons.append("CLEAN")
        }

        return Decision(action: action, threshold: t.mask, reasonCodes: reasons)
    }

    private static func maxAction(_ a: ModAction, _ b: ModAction) -> ModAction {
        a.rank >= b.rank ? a : b
    }

    private static func clamp(_ v: Double) -> Double {
        min(max(v, 0.05), 0.97)
    }

    static func redact(_ original: String, detections: [Detection]) -> String {
        guard !detections.isEmpty else { return original }
        let chars = Array(original)

        let ranges = detections.map(\.range).sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for r in ranges {
            let clipped = max(0, r.lowerBound)..<min(chars.count, r.upperBound)
            guard clipped.lowerBound < clipped.upperBound else { continue }
            if let last = merged.last, clipped.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, clipped.upperBound)
            } else {
                merged.append(clipped)
            }
        }

        var out = ""
        var cursor = 0
        for r in merged {
            if cursor < r.lowerBound { out += String(chars[cursor..<r.lowerBound]) }
            out += String(repeating: "●", count: min(max(r.count, 3), 10))
            cursor = r.upperBound
        }
        if cursor < chars.count { out += String(chars[cursor...]) }
        return out
    }
}
