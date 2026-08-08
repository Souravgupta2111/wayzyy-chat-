// Tier 2 nearest-neighbour retrieval over labelled anchors with separate positive and innocent poles.

import Foundation

struct SparseVector {
    var weights: [Int: Double]
    let norm: Double

    init(_ weights: [Int: Double]) {
        self.weights = weights
        self.norm = sqrt(weights.values.reduce(0) { $0 + $1 * $1 })
    }

    func cosine(_ other: SparseVector) -> Double {
        guard norm > 0, other.norm > 0 else { return 0 }
        let (small, large) = weights.count <= other.weights.count
            ? (weights, other.weights) : (other.weights, weights)
        var dot = 0.0
        for (k, v) in small {
            if let w = large[k] { dot += v * w }
        }
        return dot / (norm * other.norm)
    }
}

protocol Vectoriser {
    var identifier: String { get }

    var spaces: [VectorSpace] { get }

    func reading(for text: String) -> VectorReading

    func anchorVector(for text: String, in space: VectorSpace) -> SparseVector
}

extension Vectoriser {
    var primarySpace: VectorSpace { spaces[0] }

    func vector(for text: String) -> SparseVector { reading(for: text).vector }

    var enforcementThresholds: SemanticRetriever.Thresholds { primarySpace.enforcement }
    var escalationThresholds: SemanticRetriever.Thresholds { primarySpace.escalation }
}

struct VectorSpace {
    let id: String
    let enforcement: SemanticRetriever.Thresholds
    let escalation: SemanticRetriever.Thresholds
    let confidenceCeiling: Double
}

struct VectorReading {
    let vector: SparseVector
    let space: VectorSpace
}

struct LexicalVectoriser: Vectoriser {
    let identifier = "lexical-hashed-ngram-v1"

    static let space = VectorSpace(
        id: "lexical-hashed-ngram-v1",
        enforcement: .init(similarity: 0.28, margin: 0.06),
        escalation: .init(similarity: 0.24, margin: 0.05),
        confidenceCeiling: 0.62
    )

    var spaces: [VectorSpace] { [Self.space] }

    func reading(for text: String) -> VectorReading {
        VectorReading(vector: vector(for: text), space: Self.space)
    }

    func anchorVector(for text: String, in space: VectorSpace) -> SparseVector {
        vector(for: text)
    }

    private let idf: [Int: Double]
    private let dimensions = 1 << 18

    init(corpus: [String]) {
        var documentFrequency: [Int: Int] = [:]
        for document in corpus {
            for feature in Set(Self.features(document, dimensions: 1 << 18)) {
                documentFrequency[feature, default: 0] += 1
            }
        }
        let n = Double(max(corpus.count, 1))
        var table: [Int: Double] = [:]
        for (feature, df) in documentFrequency {
            table[feature] = max(log((n + 1) / (Double(df) + 1)), 0.0)
        }
        self.idf = table
    }

    func vector(for text: String) -> SparseVector {
        var counts: [Int: Double] = [:]
        for feature in Self.features(text, dimensions: dimensions) {
            counts[feature, default: 0] += 1
        }
        var weighted: [Int: Double] = [:]
        for (feature, tf) in counts {
            let weight = idf[feature] ?? 1.2
            guard weight > 0 else { continue }
            weighted[feature] = (1 + log(tf)) * weight
        }
        return SparseVector(weighted)
    }

    static func features(_ text: String, dimensions: Int) -> [Int] {
        let normalised = normalise(text)
        let tokens = normalised.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        var out: [Int] = []
        out.reserveCapacity(tokens.count * 4)

        for (i, token) in tokens.enumerated() {
            out.append(hash("w:" + token, dimensions))
            if i + 1 < tokens.count {
                out.append(hash("b:" + token + "_" + tokens[i + 1], dimensions))
            }
        }

        let chars = Array(normalised)
        if chars.count >= 4 {
            for i in 0...(chars.count - 4) {
                out.append(hash("c:" + String(chars[i..<(i + 4)]), dimensions))
            }
        }
        return out
    }

    static func normalise(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var lastWasSpace = true
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func hash(_ s: String, _ dimensions: Int) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return Int(h % UInt64(dimensions))
    }
}

enum AnchorFamily {
    case contact
    case safety
}

struct RetrievalResult {
    let intent: IntentClass
    let similarity: Double
    let negativeSimilarity: Double
    var margin: Double { similarity - negativeSimilarity }
    let nearestExemplar: String
    let space: VectorSpace
}

final class SemanticRetriever {

    struct Thresholds {
        var similarity: Double = 0.28
        var margin: Double = 0.06

        static let `default` = Thresholds()
    }

    private struct Anchors {
        let contact: [(exemplar: Exemplar, vector: SparseVector)]
        let safety: [(exemplar: Exemplar, vector: SparseVector)]
        let negatives: [SparseVector]
    }

    private let vectoriser: Vectoriser
    private let anchors: [String: Anchors]
    private let thresholdOverride: Thresholds?

    var backendIdentifier: String { vectoriser.identifier }

    var thresholds: Thresholds { thresholdOverride ?? vectoriser.primarySpace.enforcement }

    init(vectoriser: Vectoriser? = nil, thresholds: Thresholds? = nil) {
        let corpus = IntentExemplars.all.map(\.text) + IntentExemplars.negatives
        let v = vectoriser ?? LexicalVectoriser(corpus: corpus)
        self.vectoriser = v
        self.thresholdOverride = thresholds

        var built: [String: Anchors] = [:]
        for space in v.spaces {
            built[space.id] = Anchors(
                contact: IntentExemplars.contact.map { ($0, v.anchorVector(for: $0.text, in: space)) },
                safety: IntentExemplars.safety.map { ($0, v.anchorVector(for: $0.text, in: space)) },
                negatives: IntentExemplars.negatives.map { v.anchorVector(for: $0, in: space) }
            )
        }
        self.anchors = built
    }

    var escalationThresholds: Thresholds { vectoriser.primarySpace.escalation }

    func retrieve(_ text: String, family: AnchorFamily = .contact) -> RetrievalResult? {
        let normalised = LexicalVectoriser.normalise(text)
        let floor = family == .safety ? 3 : 4
        guard normalised.split(separator: " ").count >= floor else { return nil }

        let reading = vectoriser.reading(for: text)
        guard reading.vector.norm > 0,
              let set = anchors[reading.space.id] else { return nil }
        let query = reading.vector
        let positives = family == .safety ? set.safety : set.contact

        var best: (Exemplar, Double)? = nil
        for (exemplar, vector) in positives {
            let similarity = query.cosine(vector)
            if best == nil || similarity > best!.1 { best = (exemplar, similarity) }
        }
        var worstNegative = 0.0
        for vector in set.negatives {
            worstNegative = max(worstNegative, query.cosine(vector))
        }

        guard let (exemplar, similarity) = best else { return nil }
        return RetrievalResult(
            intent: exemplar.intent,
            similarity: similarity,
            negativeSimilarity: worstNegative,
            nearestExemplar: exemplar.text,
            space: reading.space
        )
    }

    func detect(_ text: String, textLength: Int, effort: Int) -> Detection? {
        guard let result = retrieve(text) else { return nil }
        let thresholds = thresholdOverride ?? result.space.enforcement
        guard result.similarity >= thresholds.similarity,
              result.margin >= thresholds.margin else { return nil }

        let span = max(result.space.confidenceCeiling - thresholds.similarity, 0.01)
        let t = min(max((result.similarity - thresholds.similarity) / span, 0), 1)
        let confidence = 0.56 + t * 0.36

        return Detection(
            category: result.intent.category,
            range: 0..<max(1, textLength),
            surface: "",
            canonical: result.intent.display,
            confidence: confidence,
            transforms: ["semantic-retrieval"],
            effort: effort,
            reason: String(
                format: "%@ — %.2f similar to a known pattern: \"%@\"",
                result.intent.display, result.similarity, result.nearestExemplar
            )
        )
    }

    func detectSafety(_ text: String, textLength: Int) -> SafetyRules.Finding? {
        guard let result = retrieve(text, family: .safety) else { return nil }
        return safetyFinding(from: result, textLength: textLength)
    }

    func safetyRetrieval(_ text: String) -> RetrievalResult? {
        retrieve(text, family: .safety)
    }

    static let safetyEnforcementFloor = 0.55
    static let safetyEnforcementMarginFloor = 0.20

    func safetyFinding(from result: RetrievalResult, textLength: Int) -> SafetyRules.Finding? {
        let base = thresholdOverride ?? result.space.enforcement
        let similarityBar = max(base.similarity + 0.06, Self.safetyEnforcementFloor)
        let marginBar = max(base.margin * 2, Self.safetyEnforcementMarginFloor)
        guard result.similarity >= similarityBar,
              result.margin >= marginBar else { return nil }

        let span = max(result.space.confidenceCeiling - similarityBar, 0.01)
        let t = min(max((result.similarity - similarityBar) / span, 0), 1)

        return SafetyRules.Finding(
            category: result.intent.category,
            confidence: 0.60 + t * 0.32,
            phrase: String(
                format: "%@ — %.2f similar to: \"%@\"",
                result.intent.display, result.similarity, result.nearestExemplar
            ),
            range: 0..<max(1, textLength)
        )
    }
}
