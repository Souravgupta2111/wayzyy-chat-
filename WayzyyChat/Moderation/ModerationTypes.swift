// Core value types: Detection, Verdict, ModAction, ModCategory, ActorContext and supporting enums.

import Foundation

enum ModAction: String, Codable, CaseIterable {
    case allow
    case hint
    case mask
    case warn
    case block
    case review

    var label: String {
        switch self {
        case .allow:  return "ALLOW"
        case .hint:   return "HINT"
        case .mask:   return "MASK"
        case .warn:   return "WARN"
        case .block:  return "BLOCK"
        case .review: return "REVIEW"
        }
    }

    var withholdsMessage: Bool {
        self == .warn || self == .block || self == .review
    }

    var rank: Int {
        switch self {
        case .allow: return 0
        case .hint: return 1
        case .mask: return 2
        case .review: return 3
        case .warn: return 4
        case .block: return 5
        }
    }
}

enum ModCategory: String, Codable, CaseIterable {
    case phone
    case email
    case socialHandle
    case externalURL
    case paymentHandle
    case cryptoAddress
    case bankDetails
    case referentialContact

    case threat
    case harassment
    case coercion
    case scam
    case sexual
    case selfHarm
    /// Refusing or conditioning accommodation on a protected characteristic. Distinct from
    /// harassment: the harm is exclusion, not insult, and in India casteist abuse is a
    /// criminal offence under the SC/ST (Prevention of Atrocities) Act.
    case discrimination
    case systemManipulation

    var display: String {
        switch self {
        case .phone:          return "Phone number"
        case .email:          return "Email address"
        case .socialHandle:   return "Social handle"
        case .externalURL:    return "External link"
        case .paymentHandle:  return "Payment handle"
        case .cryptoAddress:  return "Crypto address"
        case .bankDetails:    return "Bank details"
        case .referentialContact: return "Contact by reference"
        case .threat:         return "Threat"
        case .harassment:     return "Harassment"
        case .coercion:       return "Coercion"
        case .scam:           return "Scam / off-platform"
        case .sexual:         return "Sexual content"
        case .selfHarm:       return "Self-harm"
        case .discrimination: return "Discrimination"
        case .systemManipulation: return "Moderation tampering"
        }
    }

    var isContactExfiltration: Bool {
        switch self {
        case .phone, .email, .socialHandle, .externalURL,
             .paymentHandle, .cryptoAddress, .bankDetails, .referentialContact:
            return true
        default:
            return false
        }
    }

    var systemImage: String {
        switch self {
        case .phone:          return "phone.fill"
        case .email:          return "envelope.fill"
        case .socialHandle:   return "at"
        case .externalURL:    return "link"
        case .paymentHandle:  return "indianrupeesign.circle.fill"
        case .cryptoAddress:  return "bitcoinsign.circle.fill"
        case .bankDetails:    return "building.columns.fill"
        case .referentialContact: return "arrow.turn.up.right"
        case .threat:         return "exclamationmark.triangle.fill"
        case .harassment:     return "hand.raised.fill"
        case .coercion:       return "lock.shield.fill"
        case .scam:           return "eye.trianglebadge.exclamationmark.fill"
        case .sexual:         return "eye.slash.fill"
        case .selfHarm:       return "heart.text.square.fill"
        case .discrimination: return "person.2.slash.fill"
        case .systemManipulation: return "hammer.circle.fill"
        }
    }
}

enum EvasionLevel: String, Codable, CaseIterable {
    case l0Plain    = "L0 · Plain"
    case l1Char     = "L1 · Character"
    case l2Token    = "L2 · Token / structure"
    case l3Encoding = "L3 · Encoding"
    case l4Semantic = "L4 · Semantic / referential"
    case l5Channel  = "L5 · Distributed / covert"
    case innocent   = "FP Suite · Innocent"
    case safety     = "Safety"

    var blurb: String {
        switch self {
        case .l0Plain:    return "Unobfuscated contact details."
        case .l1Char:     return "Homoglyphs, zero-width, leet, emoji digits, fullwidth."
        case .l2Token:    return "Digit splitting, number words, embedded digits, reversal, acrostics."
        case .l3Encoding: return "Base64, hex, ROT13, binary, Morse, NATO phonetic, Roman numerals."
        case .l4Semantic: return "Arithmetic and referential indirection."
        case .l5Channel:  return "Split across messages, surfaces or time."
        case .innocent:   return "Numeric-heavy legitimate messages. Must never be flagged."
        case .safety:     return "Hostility, coercion, scam framing, self-harm."
        }
    }
}

struct Detection: Identifiable, Hashable {
    let id: UUID
    let category: ModCategory
    let range: Range<Int>
    let surface: String
    let canonical: String
    let confidence: Double
    let transforms: [String]
    let effort: Int
    let reason: String

    init(
        category: ModCategory,
        range: Range<Int>,
        surface: String,
        canonical: String,
        confidence: Double,
        transforms: [String] = [],
        effort: Int = 0,
        reason: String
    ) {
        self.id = UUID()
        self.category = category
        self.range = range
        self.surface = surface
        self.canonical = canonical
        self.confidence = confidence
        self.transforms = transforms
        self.effort = effort
        self.reason = reason
    }
}

enum TrustTier: String, Codable, CaseIterable, Identifiable {
    case fresh
    case standard
    case trusted

    var id: String { rawValue }

    var display: String {
        switch self {
        case .fresh:    return "New account"
        case .standard: return "Verified"
        case .trusted:  return "Trusted host"
        }
    }

    var thresholdOffset: Double {
        switch self {
        case .fresh:    return -0.08
        case .standard: return 0.0
        case .trusted:  return +0.10
        }
    }

    /// Wire values plus aliases a mobile client is likely to send.
    static func parse(_ raw: String?) -> TrustTier {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fresh", "new":                 return .fresh
        case "trusted", "established":       return .trusted
        case "standard", "verified", "":     return .standard
        default:                             return .standard
        }
    }
}

enum BookingStage: String, Codable, CaseIterable, Identifiable {
    case inquiry
    case booked
    case checkedIn

    var id: String { rawValue }

    var display: String {
        switch self {
        case .inquiry:   return "Inquiry"
        case .booked:    return "Booked"
        case .checkedIn: return "Checked in"
        }
    }

    var thresholdOffset: Double {
        switch self {
        case .inquiry:   return 0.0
        case .booked:    return +0.14
        case .checkedIn: return +0.22
        }
    }

    /// Wire values plus aliases a mobile client is likely to send.
    static func parse(_ raw: String?) -> BookingStage {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "booked":
            return .booked
        case "checkedin", "checked_in", "checked-in", "staying", "completed":
            return .checkedIn
        case "inquiry", "":
            return .inquiry
        default:
            return .inquiry
        }
    }
}

struct ActorContext {
    var trust: TrustTier = .standard
    var stage: BookingStage = .inquiry
    var priorViolations: Int = 0
    var conversationID: String = "demo"
    var senderID: String = "me"

    static let `default` = ActorContext()
}

struct Verdict: Identifiable {
    let id = UUID()
    let action: ModAction
    let score: Double
    let detections: [Detection]
    let categories: Set<ModCategory>
    var reasonCodes: [String]
    let tierReached: Int
    let latencyMs: Double
    let features: [(String, Double)]
    let threshold: Double
    let maskedText: String
    let redactedRanges: [Range<Int>]
    let transformsApplied: [String]
    let obfuscationEffort: Int
    var suspicions: [Suspicion] = []
    var carriers: [CarrierCandidate] = []
    var policyVersion: String = ""

    var provisionalHold: Bool = false
    var judgement: JudgementRecord? = nil

    static func clean(_ text: String, latencyMs: Double = 0) -> Verdict {
        Verdict(
            action: .allow,
            score: 0,
            detections: [],
            categories: [],
            reasonCodes: [],
            tierReached: 1,
            latencyMs: latencyMs,
            features: [],
            threshold: 0,
            maskedText: text,
            redactedRanges: [],
            transformsApplied: [],
            obfuscationEffort: 0
        )
    }

    var isClean: Bool { detections.isEmpty && action == .allow }

    var contactCategories: [ModCategory] {
        categories.filter { $0.isContactExfiltration }.sorted { $0.rawValue < $1.rawValue }
    }

    var safetyCategories: [ModCategory] {
        categories.filter { !$0.isContactExfiltration }.sorted { $0.rawValue < $1.rawValue }
    }
}

struct JudgementRecord {
    let decision: String
    let confidence: Double
    let rationale: String
    let source: String
    let latencyMs: Double
    let priorAction: ModAction
    let priorScore: Double
}
