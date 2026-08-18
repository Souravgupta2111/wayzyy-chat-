// A learned router for abuse that no list contains.
//
// What this is for
// ────────────────
// The deterministic tiers recognise abuse whose shape has been written down. Real users do not
// write down shapes. Measured against production messages: the published Hindi profanity lists
// contain `chutiya` but not `chutiye`, and no `bhosdike` at all, so a matcher built from 119
// genuine terms caught one of six real messages. Every variant, plural, misspelling and
// obfuscation would need authoring, forever, per language.
//
// This scores character n-grams instead. Trained on those same lists — as *data* rather than as
// rules — it scores `chutiye`, `chutiyapa`, `chutiyo`, `ch00tiye` and `bhosadike` without any of
// them appearing anywhere in the input. The list is what you feed it; the generalisation is the
// model's.
//
// What it is not
// ──────────────
// It never decides anything. Its output raises suspicion so that Tier 3 is asked, and policy
// still chooses the action. That division is deliberate and load-bearing: a router tuned for
// recall will be wrong in the direction of over-flagging, and the cost of being wrong must
// therefore be one model call — not a withheld message. Nothing here can enforce.
//
// Why n-grams rather than a neural model
// ─────────────────────────────────────
// It is a hash and a dot product: tens of microseconds, no network, no quota, no vendor, no
// per-message cost, and nothing leaves the process. That last point stopped being abstract when
// the most widely used free toxicity API in the industry announced its shutdown; a dependency
// you cannot lose is worth more than a slightly better score you might.
//
// The hash is FNV-1a over UTF-8 bytes because the trainer is Python and this is Swift, the two
// must agree exactly, and it has to work on Linux with no crypto dependency.

import Foundation

public final class AbuseRouter {

    /// Loaded once during bootstrap and never mutated, so reads need no synchronisation. Same
    /// reasoning as the sealed lexicons: this is on the hot path of every message.
    private let weights: [Float]
    private let buckets: Int
    private let ngrams: [Int]
    private let bias: Double

    public let weightCount: Int

    /// The score at or above which a second opinion is worth its cost.
    ///
    /// Carried in the weights file rather than hardcoded here, because it is chosen by the same
    /// sweep that fits the model — against real innocent traffic — and a scorer that disagrees
    /// with its trainer about the threshold is measuring a different model.
    public let threshold: Double

    private init(weights: [Float], buckets: Int, ngrams: [Int],
                 bias: Double, threshold: Double, nonZero: Int) {
        self.weights = weights
        self.buckets = buckets
        self.ngrams = ngrams
        self.bias = bias
        self.threshold = threshold
        self.weightCount = nonZero
    }

    /// Whether this message deserves a closer look. Never whether to act on it.
    public func routes(_ text: String) -> Bool { score(text) >= threshold }

    // MARK: - Hashing

    /// FNV-1a, 32-bit. Must stay byte-identical to `fnv1a` in tools/router/train.py.
    @inline(__always)
    private static func hash(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var h: UInt32 = 0x811C9DC5
        for b in bytes {
            h ^= UInt32(b)
            h = h &* 0x01000193
        }
        return h
    }

    // MARK: - Scoring

    /// Probability that the message is abusive, in 0...1.
    ///
    /// Normalisation matches the trainer exactly — lowercase, collapse whitespace to single
    /// spaces, pad both ends — because a scorer that preprocesses differently from its trainer
    /// is measuring something the weights were never fitted to.
    public func score(_ text: String) -> Double {
        let collapsed = text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return 0 }

        // Slice by Unicode scalar, matching Python's code-point slicing of `str`.
        let scalars = Array((" " + collapsed + " ").unicodeScalars)

        var counts: [UInt32: Float] = [:]
        counts.reserveCapacity(scalars.count * ngrams.count)

        for n in ngrams where scalars.count >= n {
            for i in 0...(scalars.count - n) {
                var view = String.UnicodeScalarView()
                for j in i..<(i + n) { view.append(scalars[j]) }
                let index = Self.hash(Array(String(view).utf8)) % UInt32(buckets)
                counts[index, default: 0] += 1
            }
        }
        guard !counts.isEmpty else { return 0 }

        var norm: Float = 0
        for v in counts.values { norm += v * v }
        norm = norm.squareRoot()
        guard norm > 0 else { return 0 }

        var z = bias
        for (index, count) in counts {
            z += Double(weights[Int(index)] * (count / norm))
        }
        z = Swift.max(-30, Swift.min(30, z))
        return 1 / (1 + exp(-z))
    }

    // MARK: - Loading

    public enum LoadError: Error, CustomStringConvertible {
        case malformed(String)

        public var description: String {
            switch self {
            case .malformed(let detail): return "abuse router weights malformed: \(detail)"
            }
        }
    }

    public static func load(contentsOf path: String) throws -> AbuseRouter {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw LoadError.malformed("unreadable at \(path)")
        }
        var buckets = 0
        var ngrams: [Int] = []
        var bias = 0.0
        var threshold = 0.5
        var declared = 0
        var weights: [Float] = []
        var nonZero = 0

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ")
            if parts.isEmpty { continue }
            switch parts[0] {
            case "WAYZYY-NGRAM-1":
                continue
            case "buckets":
                buckets = Int(parts.count > 1 ? parts[1] : "") ?? 0
                guard buckets > 0, buckets <= 1 << 24 else {
                    throw LoadError.malformed("bucket count \(buckets)")
                }
                weights = [Float](repeating: 0, count: buckets)
            case "ngrams":
                ngrams = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Int($0) }
            case "bias":
                bias = Double(parts.count > 1 ? parts[1] : "") ?? 0
            case "threshold":
                threshold = Double(parts.count > 1 ? parts[1] : "") ?? 0.5
            case "weights":
                declared = Int(parts.count > 1 ? parts[1] : "") ?? 0
            default:
                guard parts.count == 2,
                      let index = Int(parts[0]),
                      let value = Float(parts[1]),
                      index >= 0, index < weights.count
                else { continue }
                weights[index] = value
                nonZero += 1
            }
        }

        guard buckets > 0, !ngrams.isEmpty else {
            throw LoadError.malformed("missing header")
        }
        // A silently half-loaded model is worse than none: it would score every message against
        // a fraction of its weights and look like a badly calibrated router rather than a
        // truncated file.
        guard declared == 0 || declared == nonZero else {
            throw LoadError.malformed("declared \(declared) weights, read \(nonZero)")
        }
        return AbuseRouter(weights: weights, buckets: buckets, ngrams: ngrams,
                           bias: bias, threshold: threshold, nonZero: nonZero)
    }

    /// Search order mirrors the slur lexicon: explicit path, then working directory, then a
    /// system location. Absent weights are not an error — the router simply contributes nothing,
    /// and the deterministic tiers behave exactly as they did before it existed.
    static func discover() -> AbuseRouter? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["WAYZYY_ABUSE_ROUTER"], !env.isEmpty {
            candidates.append(env)
        }
        candidates.append("config/abuse-router.weights")
        candidates.append("/etc/wayzyy/abuse-router.weights")

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let router = try? load(contentsOf: path) { return router }
        }
        return nil
    }
}
