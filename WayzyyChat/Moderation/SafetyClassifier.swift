
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SafetyHead: String, CaseIterable, Codable {
    case threat
    case harassment
    case sexual
    case selfHarm
    case coercion
    case scam
    case legitimateComplaint

    var category: ModCategory? {
        switch self {
        case .threat:              return .threat
        case .harassment:          return .harassment
        case .sexual:              return .sexual
        case .selfHarm:            return .selfHarm
        case .coercion:            return .coercion
        case .scam:                return .scam
        case .legitimateComplaint: return nil
        }
    }

    var display: String {
        switch self {
        case .threat:              return "Threat"
        case .harassment:          return "Harassment"
        case .sexual:              return "Sexual"
        case .selfHarm:            return "Self-harm"
        case .coercion:            return "Coercion"
        case .scam:                return "Scam / phishing"
        case .legitimateComplaint: return "Legitimate complaint"
        }
    }
}

struct SafetyScores {
    private(set) var scores: [SafetyHead: Double] = [:]
    let source: String
    let latencyMs: Double

    init(source: String, latencyMs: Double, scores: [SafetyHead: Double] = [:]) {
        self.source = source
        self.latencyMs = latencyMs
        self.scores = scores
    }

    subscript(head: SafetyHead) -> Double { scores[head] ?? 0 }

    mutating func set(_ head: SafetyHead, _ value: Double) {
        scores[head] = Swift.min(Swift.max(value, 0), 1)
    }

    mutating func raise(_ head: SafetyHead, to value: Double) {
        set(head, Swift.max(self[head], value))
    }

    var strongestViolation: (head: SafetyHead, score: Double)? {
        let violations = scores.filter { $0.key != .legitimateComplaint }
        guard let best = violations.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        return (best.key, best.value)
    }

    var legitimateComplaint: Double { self[.legitimateComplaint] }

    var isEmpty: Bool { scores.values.allSatisfy { $0 <= 0 } }
}

enum SafetyBand {
    case allow
    case route
    case enforce
}

struct SafetyCalibration {
    var enforce: [SafetyHead: Double]
    var route: [SafetyHead: Double]

    var enforcementEnabled: Bool

    var complaintVeto: Double = 0.55

    static let `default` = SafetyCalibration(
        enforce: [
            .threat: 0.90, .harassment: 0.90, .sexual: 0.90,
            .selfHarm: 0.80, .coercion: 0.92, .scam: 0.92,
        ],
        route: [
            .threat: 0.35, .harassment: 0.40, .sexual: 0.35,
            .selfHarm: 0.30, .coercion: 0.32, .scam: 0.45,
        ],
        enforcementEnabled: false
    )

    func band(for head: SafetyHead, score: Double) -> SafetyBand {
        guard head != .legitimateComplaint else { return .allow }
        if enforcementEnabled, let bar = enforce[head], score >= bar { return .enforce }
        if let bar = route[head], score >= bar { return .route }
        return .allow
    }
}

struct SafetyClassifierInput {
    let text: String
    let deterministicFindings: [SafetyRules.Finding]
    let safetySimilarity: Double
    let innocentSimilarity: Double
    let addressesPerson: Bool
    let conditionalDemand: Bool
    let propertyDirected: Bool
    let reviewBargainScore: Double
}

protocol SafetyClassifier {
    var identifier: String { get }
    var calibration: SafetyCalibration { get }
    func classify(_ input: SafetyClassifierInput) -> SafetyScores
}

final class SignalDerivedSafetyClassifier: SafetyClassifier {
    let identifier = "signal-derived-v1"
    var calibration: SafetyCalibration

    static let marginDeadZone = 0.05

    init(calibration: SafetyCalibration = .default) {
        self.calibration = calibration
    }

    func classify(_ input: SafetyClassifierInput) -> SafetyScores {
        let started = DispatchTime.now().uptimeNanoseconds
        var out = SafetyScores(source: identifier, latencyMs: 0)

        for finding in input.deterministicFindings {
            guard let head = SafetyHead.allCases.first(where: { $0.category == finding.category })
            else { continue }
            out.raise(head, to: finding.confidence)
        }

        if input.safetySimilarity >= 0, input.innocentSimilarity >= 0 {
            let margin = input.safetySimilarity - input.innocentSimilarity
            if margin > Self.marginDeadZone {
                let weak = Swift.min(margin * 3.0, 0.72)
                out.raise(.harassment, to: weak)
                if input.addressesPerson { out.raise(.threat, to: weak * 0.85) }
            }
        }

        if input.conditionalDemand {
            out.raise(.coercion, to: input.addressesPerson ? 0.52 : 0.44)
        }
        if input.reviewBargainScore > 0 {
            out.raise(.coercion, to: input.reviewBargainScore)
        }

        var complaint = 0.0
        if input.propertyDirected { complaint = input.addressesPerson ? 0.58 : 0.72 }
        if input.innocentSimilarity >= 0.30 { complaint = Swift.max(complaint, input.innocentSimilarity) }
        if input.deterministicFindings.contains(where: { $0.confidence >= 0.90 }) { complaint = 0 }
        if input.reviewBargainScore >= 0.55 { complaint = 0 }
        out.set(.legitimateComplaint, complaint)

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return SafetyScores(source: identifier, latencyMs: elapsed, scores: out.scores)
    }
}

final class RemoteSafetyClassifier: SafetyClassifier {

    struct Configuration {
        var endpoint: URL
        var timeout: TimeInterval = 0.25
        var apiKey: String? = nil
        var wireFormat: WireFormat = .wayzyy
        var model: String? = nil
        var calibration: SafetyCalibration = {
            var c = SafetyCalibration.default
            c.enforcementEnabled = true
            return c
        }()

        static func openAIModeration(apiKey: String,
                                     model: String = "omni-moderation-latest") -> Configuration {
            var config = Configuration(
                endpoint: URL(string: "https://api.openai.com/v1/moderations")!,
                timeout: 10,
                apiKey: apiKey
            )
            config.wireFormat = .openAIModeration
            config.model = model
            config.calibration.enforcementEnabled = false
            return config
        }

        static func local(port: Int = 8_080, path: String = "/classify") -> Configuration {
            Configuration(endpoint: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        }
    }

    let identifier: String
    var calibration: SafetyCalibration { configuration.calibration }

    var fallbackCanEnforce: Bool { fallback.calibration.enforcementEnabled }

    private let configuration: Configuration
    private let session: URLSession
    private let fallback: SignalDerivedSafetyClassifier
    private let stateLock = NSLock()
    private var consecutiveFailures = 0
    private var disabledUntil: Date? = nil
    private(set) var lastFailure: String? = nil
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: Set<String> = []

    var fallbackCalibration: SafetyCalibration { fallback.calibration }

    init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        self.identifier = "remote-classifier-\(configuration.endpoint.host ?? "local")"

        var routingOnly = configuration.calibration
        routingOnly.enforcementEnabled = false
        self.fallback = SignalDerivedSafetyClassifier(calibration: routingOnly)
    }

    func classify(_ input: SafetyClassifierInput) -> SafetyScores {
        if let cached = cachedScores(for: input.text) {
            return SafetyScores(source: identifier + "-cached", latencyMs: 0, scores: cached)
        }

        stateLock.lock()
        let coolingDown = disabledUntil.map { Date() < $0 } ?? false
        stateLock.unlock()
        if !coolingDown { refreshInBackground(input.text) }

        return fallback.classify(input)
    }


    private struct CacheEntry {
        let scores: [SafetyHead: Double]
        let at: Date
    }

    private static let cacheTTL: TimeInterval = 15 * 60
    private static let cacheLimit = 5_000

    private func cachedScores(for text: String) -> [SafetyHead: Double]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let entry = cache[text] else { return nil }
        guard Date().timeIntervalSince(entry.at) < Self.cacheTTL else {
            cache.removeValue(forKey: text)
            return nil
        }
        return entry.scores
    }

    private func store(_ scores: [SafetyHead: Double], for text: String) {
        stateLock.lock()
        if cache.count >= Self.cacheLimit {
            let oldest = cache.sorted { $0.value.at < $1.value.at }
                .prefix(Self.cacheLimit / 4)
                .map(\.key)
            for key in oldest { cache.removeValue(forKey: key) }
        }
        cache[text] = CacheEntry(scores: scores, at: Date())
        consecutiveFailures = 0
        disabledUntil = nil
        stateLock.unlock()
    }

    private func refreshInBackground(_ text: String) {
        stateLock.lock()
        let alreadyFetching = inFlight.contains(text)
        if !alreadyFetching { inFlight.insert(text) }
        stateLock.unlock()
        guard !alreadyFetching else { return }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = configuration.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: configuration.wireFormat.requestBody(text: text,
                                                                model: configuration.model))

        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            self.stateLock.lock()
            self.inFlight.remove(text)
            self.stateLock.unlock()

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data, let parsed = self.configuration.wireFormat.parse(data)
            else {
                self.noteFailure(reason: "no usable response from classifier endpoint")
                return
            }
            self.store(parsed, for: text)
        }.resume()
    }

    static func parse(_ data: Data) -> [SafetyHead: Double]? {
        WireFormat.wayzyy.parse(data)
    }

    enum WireFormat {
        case wayzyy
        case openAIModeration

        func requestBody(text: String, model: String?) -> [String: Any] {
            switch self {
            case .wayzyy:
                return ["text": text]
            case .openAIModeration:
                return ["model": model ?? "omni-moderation-latest", "input": text]
            }
        }

        func parse(_ data: Data) -> [SafetyHead: Double]? {
            switch self {
            case .wayzyy:
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                let body = (root["scores"] as? [String: Any]) ?? root
                var out: [SafetyHead: Double] = [:]
                for head in SafetyHead.allCases {
                    let snake = head.rawValue
                        .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2",
                                              options: .regularExpression)
                        .lowercased()
                    let raw = body[head.rawValue] ?? body[snake]
                    if let d = raw as? Double { out[head] = d }
                    else if let n = raw as? NSNumber { out[head] = n.doubleValue }
                }
                return out.isEmpty ? nil : out

            case .openAIModeration:
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = root["results"] as? [[String: Any]],
                      let first = results.first,
                      let raw = first["category_scores"] as? [String: Any]
                else { return nil }

                func value(_ key: String) -> Double {
                    if let d = raw[key] as? Double { return d }
                    if let n = raw[key] as? NSNumber { return n.doubleValue }
                    return 0
                }
                var out: [SafetyHead: Double] = [:]
                func raise(_ head: SafetyHead, _ v: Double) {
                    out[head] = Swift.max(out[head] ?? 0, v)
                }
                raise(.harassment, value("harassment"))
                raise(.harassment, value("harassment/threatening"))
                raise(.harassment, value("hate"))
                raise(.harassment, value("hate/threatening"))
                raise(.threat, value("harassment/threatening"))
                raise(.threat, value("hate/threatening"))
                raise(.threat, value("violence"))
                raise(.threat, value("violence/graphic"))
                raise(.sexual, value("sexual"))
                raise(.sexual, value("sexual/minors"))
                raise(.selfHarm, value("self-harm"))
                raise(.selfHarm, value("self-harm/intent"))
                raise(.selfHarm, value("self-harm/instructions"))
                return out.values.contains(where: { $0 > 0 }) ? out : nil
            }
        }
    }

    private func noteFailure(reason: String) {
        stateLock.lock()
        consecutiveFailures += 1
        lastFailure = reason
        if consecutiveFailures >= 3 {
            disabledUntil = Date().addingTimeInterval(30)
        }
        stateLock.unlock()
    }

    private func recordFailure(_ input: SafetyClassifierInput, reason: String) -> SafetyScores {
        stateLock.lock()
        consecutiveFailures += 1
        lastFailure = reason
        if consecutiveFailures >= 3 {
            disabledUntil = Date().addingTimeInterval(30)
        }
        stateLock.unlock()
        return degrade(input, reason: reason)
    }

    private func degrade(_ input: SafetyClassifierInput, reason: String) -> SafetyScores {
        let scores = fallback.classify(input)
        return SafetyScores(
            source: "\(identifier)→degraded(\(fallback.identifier))",
            latencyMs: scores.latencyMs,
            scores: scores.scores
        )
    }
}

extension SafetyCalibration {

    struct Outcome {
        var finding: SafetyRules.Finding? = nil
        var shouldRoute = false
        var reasonCodes: [String] = []
        var drivingHead: SafetyHead? = nil
        var drivingScore: Double = 0
        var complaintVetoed = false
    }

    func apply(_ scores: SafetyScores, textLength: Int) -> Outcome {
        var out = Outcome()
        guard let (head, score) = scores.strongestViolation else { return out }
        out.drivingHead = head
        out.drivingScore = score

        let band = band(for: head, score: score)
        guard band != .allow else { return out }

        let vetoed = scores.legitimateComplaint >= complaintVeto && head != .coercion
        if vetoed { out.complaintVetoed = true }

        switch band {
        case .allow:
            break
        case .route:
            out.shouldRoute = true
            out.reasonCodes.append(
                String(format: "LAYER3_ROUTE(%@ %.2f)", head.rawValue, score))
        case .enforce:
            if vetoed {
                out.shouldRoute = true
                out.reasonCodes.append(
                    String(format: "LAYER3_COMPLAINT_VETO(%.2f)", scores.legitimateComplaint))
            } else if let category = head.category {
                out.finding = SafetyRules.Finding(
                    category: category,
                    confidence: score,
                    phrase: String(format: "%@ — classifier %.2f (%@)",
                                   head.display, score, scores.source),
                    range: 0..<Swift.max(1, textLength)
                )
                out.reasonCodes.append(
                    String(format: "LAYER3_ENFORCED(%@ %.2f)", head.rawValue, score))
            }
        }
        return out
    }
}
