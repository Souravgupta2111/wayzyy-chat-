
import Foundation

public final class AbuseRouter {

    private let weights: [Float]
    private let buckets: Int
    private let ngrams: [Int]
    private let bias: Double

    public let weightCount: Int

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

    public func routes(_ text: String) -> Bool { score(text) >= threshold }


    @inline(__always)
    private static func hash(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var h: UInt32 = 0x811C9DC5
        for b in bytes {
            h ^= UInt32(b)
            h = h &* 0x01000193
        }
        return h
    }


    public func score(_ text: String) -> Double {
        let collapsed = text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return 0 }

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
        guard declared == 0 || declared == nonZero else {
            throw LoadError.malformed("declared \(declared) weights, read \(nonZero)")
        }
        return AbuseRouter(weights: weights, buckets: buckets, ngrams: ngrams,
                           bias: bias, threshold: threshold, nonZero: nonZero)
    }

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
