// Optional embedding backend for retrieval, with degradation to the lexical vector space.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class EmbeddingVectoriser: Vectoriser {

    struct Configuration {
        var baseURL: URL
        var model: String
        var apiKey: String?
        var timeout: TimeInterval = 30
        var fallbackToLexical: Bool = true

        static func ollama(
            model: String = "nomic-embed-text",
            host: String = "127.0.0.1",
            port: Int = 11_434
        ) -> Configuration {
            Configuration(
                baseURL: URL(string: "http://\(host):\(port)/v1/embeddings")!,
                model: model,
                apiKey: nil
            )
        }
    }

    let identifier: String
    private let configuration: Configuration
    private let fallback: LexicalVectoriser
    private let session: URLSession

    private let embeddingSpace: VectorSpace

    var spaces: [VectorSpace] { [embeddingSpace, LexicalVectoriser.space] }

    func reading(for text: String) -> VectorReading {
        let key = LexicalVectoriser.normalise(text)

        cacheLock.lock()
        let hit = cache[key]
        cacheLock.unlock()
        if let hit {
            return VectorReading(vector: hit, space: embeddingSpace)
        }

        warmInBackground(key: key, text: text)
        return VectorReading(vector: fallback.vector(for: text), space: LexicalVectoriser.space)
    }

    func anchorVector(for text: String, in space: VectorSpace) -> SparseVector {
        guard space.id == embeddingSpace.id else { return fallback.vector(for: text) }
        guard let dense = embed(text) else {
            print("[EmbeddingVectoriser] anchor embed failed, corpus incomplete: \(text.prefix(48))")
            return SparseVector([:])
        }
        let vector = Self.sparse(from: dense)
        cacheLock.lock()
        cache[LexicalVectoriser.normalise(text)] = vector
        cacheLock.unlock()
        return vector
    }

    private static func sparse(from dense: [Double]) -> SparseVector {
        var components: [Int: Double] = [:]
        components.reserveCapacity(dense.count)
        for (i, value) in dense.enumerated() where value != 0 { components[i] = value }
        return SparseVector(components)
    }

    private var cache: [String: SparseVector] = [:]
    private let cacheLock = NSLock()

    init(configuration: Configuration, corpus: [String]) {
        self.configuration = configuration
        self.identifier = "embedding-\(configuration.model)"
        self.fallback = LexicalVectoriser(corpus: corpus)
        self.embeddingSpace = VectorSpace(
            id: "embedding-\(configuration.model)",
            enforcement: .init(similarity: 0.60, margin: 0.05),
            escalation: .init(similarity: 0.55, margin: 0.05),
            confidenceCeiling: 0.90
        )
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = configuration.timeout
        self.session = URLSession(configuration: config)
    }

    func probe() -> Bool {
        embed("probe") != nil
    }

    private func warmInBackground(key: String, text: String) {
        cacheLock.lock()
        if inFlight.contains(key) { cacheLock.unlock(); return }
        inFlight.insert(key)
        cacheLock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let dense = self.embed(text)
            self.cacheLock.lock()
            self.inFlight.remove(key)
            if let dense, !dense.isEmpty {
                if self.cache.count > 20_000 { self.cache.removeAll(keepingCapacity: true) }
                self.cache[key] = Self.sparse(from: dense)
            }
            self.cacheLock.unlock()
        }
    }

    private var inFlight: Set<String> = []

    private func embed(_ text: String) -> [Double]? {
        var request = URLRequest(url: configuration.baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = configuration.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["model": configuration.model, "input": text]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var result: [Double]? = nil
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = root["data"] as? [[String: Any]],
                  let raw = items.first?["embedding"] as? [Any]
            else { return }
            result = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
        }.resume()
        _ = semaphore.wait(timeout: .now() + configuration.timeout)
        return (result?.isEmpty ?? true) ? nil : result
    }
}

extension SemanticRetriever {
    static func embeddingBacked(
        configuration: EmbeddingVectoriser.Configuration = .ollama(),
        thresholds: Thresholds? = nil
    ) -> SemanticRetriever? {
        let corpus = IntentExemplars.all.map(\.text) + IntentExemplars.negatives
        let vectoriser = EmbeddingVectoriser(configuration: configuration, corpus: corpus)
        guard vectoriser.probe() else { return nil }

        return SemanticRetriever(vectoriser: vectoriser, thresholds: thresholds)
    }
}
