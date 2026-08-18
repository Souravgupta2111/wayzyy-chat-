// Postgres-backed DecisionStore via the Supabase REST API.
//
// Why Supabase REST and not a native Postgres driver
// ──────────────────────────────────────────────────
// The package has no external dependencies, and keeping that constraint means the gate
// runs offline on every build, on every machine, with no `swift package resolve`. A native
// Postgres driver (PostgresNIO, Vapor Fluent) would need Package.swift to declare a
// dependency and a network call to resolve it.
//
// The Supabase REST API is standard HTTPS. Foundation's URLSession handles it, which is
// already in the binary. The trade-off: one extra round-trip to confirm a transaction rather
// than a single pipelined statement, and slightly higher latency than a persistent TCP
// connection. At the call volumes this store handles — decisions, not messages — neither
// matters.
//
// Schema (run this once in Supabase SQL editor)
// ─────────────────────────────────────────────
//   create table if not exists mod_decisions (
//     request_id    text primary key,
//     conversation_id text not null,
//     sender_id     text not null,
//     decision      jsonb not null,
//     recorded_at   timestamptz not null default now()
//   );
//
//   create table if not exists mod_outbox (
//     id            text primary key,
//     request_id    text not null,
//     kind          text not null,
//     subject       text not null,
//     occurred_at   timestamptz not null,
//     delivered     boolean not null default false
//   );
//
//   -- Index for the replay query (events since a cutoff, used on startup).
//   create index if not exists mod_outbox_occurred_at
//     on mod_outbox (occurred_at) where not delivered;
//
//   -- Row-level security: the service role key bypasses RLS, so you can leave it
//   -- enabled on both tables and add user-facing policies separately without
//   -- changing anything here.
//   alter table mod_decisions enable row level security;
//   alter table mod_outbox     enable row level security;

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class PostgresDecisionStore: DecisionStore {

    // MARK: - Configuration

    public struct Configuration {
        /// `https://<project>.supabase.co`
        public var projectURL: URL
        /// Service role key. Has write access and bypasses RLS. Never expose to clients.
        public var serviceRoleKey: String
        /// Network timeout for each REST call. Decisions are on the write path so keep
        /// this short — the file store fallback is the recovery, not a long wait.
        public var timeout: TimeInterval = 5

        public init(projectURL: URL, serviceRoleKey: String, timeout: TimeInterval = 5) {
            self.projectURL = projectURL
            self.serviceRoleKey = serviceRoleKey
            self.timeout = timeout
        }

        /// Read from environment variables — the standard Supabase pattern.
        ///
        /// Set `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` in your container's
        /// environment or in a mounted secret file.
        public static func fromEnvironment() -> Configuration? {
            let env = ProcessInfo.processInfo.environment
            guard let raw = env["SUPABASE_URL"],
                  let url = URL(string: raw),
                  let key = env["SUPABASE_SERVICE_ROLE_KEY"], !key.isEmpty
            else { return nil }
            return Configuration(projectURL: url, serviceRoleKey: key)
        }
    }

    // MARK: - State

    private let config: Configuration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // In-process LRU so reads (idempotency lookups) do not always go to the network.
    private let cacheLock = NSLock()
    private var cache: [String: DecisionEnvelope] = [:]
    private var lru: [String] = []
    private let maxCacheEntries = 10_000

    // MARK: - Init

    public init(configuration: Configuration) {
        self.config = configuration
        let sc = URLSessionConfiguration.default
        sc.timeoutIntervalForRequest = configuration.timeout
        sc.timeoutIntervalForResource = configuration.timeout * 3
        self.session = URLSession(configuration: sc)
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = []
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - DecisionStore

    public func commit(_ envelope: DecisionEnvelope, event: OutboxEvent) throws {
        _ = try commitIfAbsent(envelope, event: event)
    }

    public func commitIfAbsent(_ envelope: DecisionEnvelope, event: OutboxEvent) throws -> DecisionEnvelope {
        if let existing = decision(forRequestID: envelope.requestID) { return existing }

        let row: [String: Any] = [
            "request_id":      envelope.requestID,
            "conversation_id": envelope.conversationID,
            "sender_id":       envelope.senderID,
            "decision":        (try? encoder.encode(envelope.decision))
                               .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:],
            "recorded_at":     ISO8601DateFormatter().string(from: envelope.recordedAt),
        ]
        try postgresUpsert(table: "mod_decisions", row: row)

        // The row that actually exists is the canonical decision — a concurrent writer may
        // have landed first under ignore-duplicates.
        guard let stored = decision(forRequestID: envelope.requestID) else {
            throw DecisionStoreError.notWritable("decision insert did not round-trip")
        }

        do {
            try commitEvent(event)
        } catch {
            // Two REST calls cannot be a SQL transaction. Roll the decision back so a 503
            // means "neither was recorded" rather than "decision without an outbox event".
            try? postgresDelete(table: "mod_decisions",
                                query: "request_id=\(Self.pgEq(envelope.requestID))")
            cacheLock.lock()
            cache.removeValue(forKey: envelope.requestID)
            if let i = lru.firstIndex(of: envelope.requestID) { lru.remove(at: i) }
            cacheLock.unlock()
            throw error
        }

        remember(stored)
        return stored
    }

    public func reserve(_ envelope: DecisionEnvelope) throws -> (acquired: Bool, envelope: DecisionEnvelope) {
        if let existing = decision(forRequestID: envelope.requestID) {
            if existing.decision.isReservation,
               Date().timeIntervalSince(existing.recordedAt) > 15 {
                // Steal expired reservation by patching only while still pending.
                if try postgresPatchPending(envelope) {
                    remember(envelope)
                    return (true, envelope)
                }
                if let again = decision(forRequestID: envelope.requestID),
                   !again.decision.isReservation {
                    return (false, again)
                }
            }
            return (false, existing)
        }

        let row = try decisionRow(envelope)
        let inserted = try postgresUpsertReturning(table: "mod_decisions", row: row)
        if !inserted.isEmpty {
            remember(envelope)
            return (true, envelope)
        }
        guard let stored = decision(forRequestID: envelope.requestID) else {
            throw DecisionStoreError.notWritable("reserve did not round-trip")
        }
        return (false, stored)
    }

    public func finalize(_ envelope: DecisionEnvelope, event: OutboxEvent) throws -> DecisionEnvelope {
        if let existing = decision(forRequestID: envelope.requestID),
           !existing.decision.isReservation {
            return existing
        }
        if try postgresPatchPending(envelope) {
            do {
                try commitEvent(event)
            } catch {
                try? postgresDelete(table: "mod_decisions",
                                    query: "request_id=\(Self.pgEq(envelope.requestID))")
                cacheLock.lock()
                cache.removeValue(forKey: envelope.requestID)
                if let i = lru.firstIndex(of: envelope.requestID) { lru.remove(at: i) }
                cacheLock.unlock()
                throw error
            }
            remember(envelope)
            return envelope
        }
        guard let stored = decision(forRequestID: envelope.requestID) else {
            throw DecisionStoreError.notWritable("finalize did not round-trip")
        }
        if stored.decision.isReservation {
            // Lost the pending patch; insert as a fresh commit if the row vanished.
            return try commitIfAbsent(envelope, event: event)
        }
        return stored
    }

    public func commit(event: OutboxEvent) throws {
        try commitEvent(event)
    }

    public func decision(forRequestID requestID: String) -> DecisionEnvelope? {
        cacheLock.lock()
        if let cached = cache[requestID], !cached.decision.isReservation {
            touchLocked(requestID)
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let url = config.projectURL
            .appendingPathComponent("rest/v1/mod_decisions")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "request_id", value: Self.pgEq(requestID)),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let fetchURL = components.url else { return nil }

        var req = baseRequest(url: fetchURL)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")

        guard let (data, _) = try? syncRequest(req),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first
        else { return nil }

        guard let envelope = decisionFromRow(first) else { return nil }
        if !envelope.decision.isReservation { remember(envelope) }
        return envelope
    }

    private func remember(_ envelope: DecisionEnvelope) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[envelope.requestID] = envelope
        touchLocked(envelope.requestID)
        while cache.count > maxCacheEntries, let oldest = lru.first {
            lru.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func touchLocked(_ id: String) {
        if let i = lru.firstIndex(of: id) { lru.remove(at: i) }
        lru.append(id)
    }

    public func pendingEvents(limit: Int) -> [OutboxEvent] {
        let url = config.projectURL
            .appendingPathComponent("rest/v1/mod_outbox")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "delivered", value: "eq.false"),
            URLQueryItem(name: "order", value: "occurred_at.asc"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        guard let fetchURL = components.url else { return [] }
        var req = baseRequest(url: fetchURL)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? syncRequest(req),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap(outboxEventFromRow)
    }

    public func markDelivered(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let inList = ids.map { id -> String in
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
            return "\"\(encoded)\""
        }.joined(separator: ",")
        let url = config.projectURL
            .appendingPathComponent("rest/v1/mod_outbox")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: "in.(\(inList))"),
        ]
        guard let patchURL = components.url else { return }
        var req = baseRequest(url: patchURL)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["delivered": true])
        guard let (_, response) = try? syncRequest(req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw DecisionStoreError.notWritable("markDelivered PATCH failed")
        }
    }

    public func events(since: Date) -> [OutboxEvent] {
        let fmt = ISO8601DateFormatter()
        let url = config.projectURL
            .appendingPathComponent("rest/v1/mod_outbox")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "occurred_at", value: Self.pgGte(fmt.string(from: since))),
            URLQueryItem(name: "order", value: "occurred_at.asc"),
        ]
        guard let fetchURL = components.url else { return [] }
        var req = baseRequest(url: fetchURL)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? syncRequest(req),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap(outboxEventFromRow)
    }

    public var committedDecisions: Int {
        // HEAD with count=exact — Supabase returns it in the Content-Range header.
        let url = config.projectURL.appendingPathComponent("rest/v1/mod_decisions")
        var req = baseRequest(url: url)
        req.httpMethod = "HEAD"
        req.setValue("exact", forHTTPHeaderField: "Prefer")
        req.setValue("0-0", forHTTPHeaderField: "Range")
        guard let (_, response) = try? syncRequest(req),
              let http = response as? HTTPURLResponse,
              let range = http.value(forHTTPHeaderField: "Content-Range")
        else { return 0 }
        // Format: "0-0/1234"
        return Int(range.split(separator: "/").last ?? "") ?? 0
    }

    // MARK: - Private helpers

    private func baseRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = config.timeout
        req.setValue("Bearer \(config.serviceRoleKey)", forHTTPHeaderField: "Authorization")
        req.setValue(config.serviceRoleKey, forHTTPHeaderField: "apikey")
        return req
    }

    private static func pgEq(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "eq.\(encoded)"
    }

    private static func pgGte(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:+"))
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "gte.\(encoded)"
    }

    private func postgresDelete(table: String, query: String) throws {
        let url = config.projectURL.appendingPathComponent("rest/v1/\(table)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.query = query
        guard let deleteURL = components.url else {
            throw DecisionStoreError.notWritable("bad delete URL")
        }
        var req = baseRequest(url: deleteURL)
        req.httpMethod = "DELETE"
        _ = try? syncRequest(req)
    }

    private func postgresUpsert(table: String, row: [String: Any]) throws {
        let url = config.projectURL.appendingPathComponent("rest/v1/\(table)")
        var req = baseRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("resolution=ignore-duplicates", forHTTPHeaderField: "Prefer")
        req.httpBody = try? JSONSerialization.data(withJSONObject: row)
        guard let (_, response) = try? syncRequest(req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw DecisionStoreError.notWritable("upsert into \(table) failed")
        }
    }

    private func commitEvent(_ event: OutboxEvent) throws {
        let fmt = ISO8601DateFormatter()
        let row: [String: Any] = [
            "id":          event.id,
            "request_id":  event.requestID,
            "kind":        event.kind.rawValue,
            "subject":     event.subject,
            "occurred_at": fmt.string(from: event.occurredAt),
            "delivered":   event.delivered,
        ]
        try postgresUpsert(table: "mod_outbox", row: row)
    }

    private func decisionRow(_ envelope: DecisionEnvelope) throws -> [String: Any] {
        [
            "request_id":      envelope.requestID,
            "conversation_id": envelope.conversationID,
            "sender_id":       envelope.senderID,
            "decision":        (try? encoder.encode(envelope.decision))
                               .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:],
            "recorded_at":     ISO8601DateFormatter().string(from: envelope.recordedAt),
        ]
    }

    /// PATCH only while the stored action is still the reservation placeholder.
    @discardableResult
    private func postgresPatchPending(_ envelope: DecisionEnvelope) throws -> Bool {
        let url = config.projectURL.appendingPathComponent("rest/v1/mod_decisions")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "request_id", value: Self.pgEq(envelope.requestID)),
            URLQueryItem(name: "decision->>action", value: "eq.\(DecisionRecord.reservationAction)"),
        ]
        guard let patchURL = components.url else { return false }
        var req = baseRequest(url: patchURL)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONSerialization.data(withJSONObject: try decisionRow(envelope))
        guard let (data, response) = try? syncRequest(req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return false }
        let rows = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return !rows.isEmpty
    }

    private func postgresUpsertReturning(table: String, row: [String: Any]) throws -> [[String: Any]] {
        let url = config.projectURL.appendingPathComponent("rest/v1/\(table)")
        var req = baseRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=representation,resolution=ignore-duplicates", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONSerialization.data(withJSONObject: row)
        guard let (data, response) = try? syncRequest(req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw DecisionStoreError.notWritable("upsert into \(table) failed")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// Synchronous wrapper around URLSession. The store is called from synchronous
    /// contexts (the write path in ModerationService), so we have to block. The timeout
    /// on the session configuration bounds how long we block.
    private func syncRequest(_ request: URLRequest) throws -> (Data, URLResponse) {
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + (config.timeout + 1))
        if let error = resultError { throw error }
        guard let data = resultData, let response = resultResponse else {
            throw DecisionStoreError.notWritable("no response from Supabase")
        }
        return (data, response)
    }

    // MARK: - Row deserialisers

    private func decisionFromRow(_ row: [String: Any]) -> DecisionEnvelope? {
        guard let requestID = row["request_id"] as? String,
              let conversationID = row["conversation_id"] as? String,
              let senderID = row["sender_id"] as? String,
              let decisionJSON = row["decision"]
        else { return nil }

        let decisionData: Data
        if let d = try? JSONSerialization.data(withJSONObject: decisionJSON) {
            decisionData = d
        } else { return nil }

        guard let decision = try? decoder.decode(DecisionRecord.self, from: decisionData)
        else { return nil }

        let recordedAt: Date
        if let ts = row["recorded_at"] as? String {
            recordedAt = ISO8601DateFormatter().date(from: ts) ?? Date()
        } else { recordedAt = Date() }

        return DecisionEnvelope(requestID: requestID, conversationID: conversationID,
                                senderID: senderID, decision: decision,
                                recordedAt: recordedAt)
    }

    private func outboxEventFromRow(_ row: [String: Any]) -> OutboxEvent? {
        guard let id       = row["id"] as? String,
              let requestID = row["request_id"] as? String,
              let kindRaw  = row["kind"] as? String,
              let kind     = OutboxEvent.Kind(rawValue: kindRaw),
              let subject  = row["subject"] as? String
        else { return nil }

        let occurredAt: Date
        if let ts = row["occurred_at"] as? String {
            occurredAt = ISO8601DateFormatter().date(from: ts) ?? Date()
        } else { occurredAt = Date() }

        let delivered = (row["delivered"] as? Bool) ?? false
        return OutboxEvent(id: id, requestID: requestID, kind: kind,
                           subject: subject, occurredAt: occurredAt,
                           delivered: delivered)
    }
}
