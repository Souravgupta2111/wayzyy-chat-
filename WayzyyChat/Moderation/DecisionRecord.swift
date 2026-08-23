
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
    public var policyVersion: String
    public var provisionalHold: Bool
    public var decidedAt: Date
    public var detections: [DetectionRecord]

    public var reDerived: Bool = false

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


extension Verdict {

    var decisionRecord: DecisionRecord {
        DecisionRecord(
            action: action.rawValue,
            score: score,
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
