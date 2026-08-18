// A durable, policy-independent record of a moderation decision.
//
// Why this type exists
// ────────────────────
// A verdict is a *historical fact*: "at 14:02 on 3 June, under policy v7, this message was
// withheld." Re-running the engine over stored text does not recover that fact — it produces a
// fresh opinion under whatever policy happens to be loaded now. The two are routinely
// different, and treating the second as the first has three consequences:
//
//   1. History silently rewrites itself. Raise a threshold and messages that were delivered
//      months ago start rendering as withheld, and messages that were withheld start
//      rendering as delivered. Nobody edited anything; the past simply changed.
//   2. Appeals become unanswerable. "Why was my message blocked?" can only be answered with
//      the policy, score and reason codes that were actually in force at the time.
//   3. Re-derivation is unbounded work on a hot path, and it replays side effects — actor
//      signals and conversation buffers get fed historical messages as though they were new.
//
// So the decision is stored, not recomputed. Restoration is a pure deserialisation: no engine
// call, no policy read, no side effects.
//
// Everything here is primitive-typed on purpose. This is a wire and storage format — it lands
// in a JSON column or a Kafka message — so it must not depend on the internal enums, and must
// survive a category or action being added, removed or renamed in a later build.

import Foundation

public struct DetectionRecord: Codable, Equatable {
    public var category: String
    public var lower: Int
    public var upper: Int
    public var surface: String
    public var canonical: String
    public var confidence: Double
    public var transforms: [String]
    public var effort: Int
    public var reason: String
}

public struct DecisionRecord: Codable, Equatable {
    public var action: String
    public var score: Double
    public var categories: [String]
    public var reasonCodes: [String]
    public var tierReached: Int
    public var threshold: Double
    public var latencyMs: Double
    public var maskedText: String
    public var redactedRanges: [[Int]]
    public var transformsApplied: [String]
    public var obfuscationEffort: Int
    /// The policy version in force when this decision was made. The whole point of the
    /// record: it pins the decision to the rules that produced it.
    public var policyVersion: String
    public var provisionalHold: Bool
    public var decidedAt: Date
    public var detections: [DetectionRecord]

    /// Set when a record could not be restored and had to be re-derived — a legacy row written
    /// before decisions were durable. Callers that care about auditability can treat a
    /// re-derived decision as an estimate rather than evidence.
    public var reDerived: Bool = false

    /// Placeholder written before evaluation so two replicas cannot both judge the same id.
    public static let reservationAction = "__pending__"

    public var isReservation: Bool { action == Self.reservationAction }

    public static func reservation() -> DecisionRecord {
        DecisionRecord(
            action: reservationAction,
            score: 0,
            categories: [],
            reasonCodes: ["PENDING"],
            tierReached: 0,
            threshold: 0,
            latencyMs: 0,
            maskedText: "",
            redactedRanges: [],
            transformsApplied: [],
            obfuscationEffort: 0,
            policyVersion: "",
            provisionalHold: true,
            decidedAt: Date(),
            detections: []
        )
    }
}

// MARK: - Bridging

extension Verdict {

    /// Capture this verdict as a durable record.
    var decisionRecord: DecisionRecord {
        DecisionRecord(
            action: action.rawValue,
            score: score,
            // Sorted so the record is byte-stable: `Set` iteration order is not, and an
            // unstable serialisation defeats checksums, diffing and idempotent writes.
            categories: categories.map(\.rawValue).sorted(),
            reasonCodes: reasonCodes,
            tierReached: tierReached,
            threshold: threshold,
            latencyMs: latencyMs,
            maskedText: maskedText,
            redactedRanges: redactedRanges.map { [$0.lowerBound, $0.upperBound] },
            transformsApplied: transformsApplied,
            obfuscationEffort: obfuscationEffort,
            policyVersion: policyVersion,
            provisionalHold: provisionalHold,
            decidedAt: Date(),
            detections: detections.map {
                DetectionRecord(
                    category: $0.category.rawValue,
                    lower: $0.range.lowerBound,
                    upper: $0.range.upperBound,
                    surface: $0.surface,
                    canonical: $0.canonical,
                    confidence: $0.confidence,
                    transforms: $0.transforms,
                    effort: $0.effort,
                    reason: $0.reason
                )
            }
        )
    }

    /// Rebuild a verdict from a stored record.
    ///
    /// Pure: reads no policy and calls no engine. An action or category this build no longer
    /// recognises is dropped rather than treated as an error — a decision from a future or
    /// retired policy is still a fact, and losing the row entirely would be worse than losing
    /// one label from it.
    init(restoring record: DecisionRecord) {
        self.init(
            action: ModAction(rawValue: record.action) ?? .allow,
            score: record.score,
            detections: record.detections.map {
                Detection(
                    category: ModCategory(rawValue: $0.category) ?? .systemManipulation,
                    range: $0.lower..<max($0.lower, $0.upper),
                    surface: $0.surface,
                    canonical: $0.canonical,
                    confidence: $0.confidence,
                    transforms: $0.transforms,
                    effort: $0.effort,
                    reason: $0.reason
                )
            },
            categories: Set(record.categories.compactMap { ModCategory(rawValue: $0) }),
            reasonCodes: record.reasonCodes,
            tierReached: record.tierReached,
            latencyMs: record.latencyMs,
            features: [],
            threshold: record.threshold,
            maskedText: record.maskedText,
            redactedRanges: record.redactedRanges.compactMap {
                $0.count == 2 ? $0[0]..<max($0[0], $0[1]) : nil
            },
            transformsApplied: record.transformsApplied,
            obfuscationEffort: record.obfuscationEffort,
            policyVersion: record.policyVersion,
            provisionalHold: record.provisionalHold
        )
    }
}
