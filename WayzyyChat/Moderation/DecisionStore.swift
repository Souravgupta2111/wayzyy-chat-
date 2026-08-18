// Durable storage for decisions, and the outbox that tells the rest of the platform about them.
//
// Why a decision has to be written down
// ─────────────────────────────────────
// `DecisionRecord` gave decisions a *format*. This gives them a *home*. Without one the service
// holds every decision, report and block in memory, so a restart — a deploy, a crash, a node
// eviction — silently erases the platform's entire enforcement history. Three things break:
//
//   * Appeals. "Why was my message withheld?" has no answer if the answer was in a dead pod.
//   * Behavioural detection. Reports and blocks are the highest-precision evidence the system
//     has and the only label source in a design with no human review tier. Losing them resets
//     every repeat offender to a clean slate on every deploy.
//   * Idempotency. A client that retries a timed-out request gets a second evaluation instead
//     of the original decision, so a retry can change an outcome.
//
// Two design choices worth stating plainly.
//
// **Commit is one operation, not two.** A decision that is stored without its outbox event is
// invisible to the rest of the platform; an event emitted without its decision points at
// nothing. `commit` therefore takes both and is required to persist them together or neither. A
// SQL implementation satisfies this with a transaction. The file implementation satisfies it by
// writing a single line and flushing it, which is why the record and event share one envelope.
//
// **Durability is the interface's promise, not the caller's problem.** `commit` is declared
// `throws` and callers are expected to treat a failure as a failure — a decision that could not
// be recorded must not be delivered as though it had been. That is the one place this design
// deliberately fails closed on infrastructure rather than on content.

import Foundation

/// A decision plus the identifiers needed to find it again.
public struct DecisionEnvelope: Codable, Equatable {
    /// The client's idempotency key. A retry carrying the same value must return the stored
    /// decision rather than produce a new one.
    public var requestID: String
    public var conversationID: String
    public var senderID: String
    public var decision: DecisionRecord
    public var recordedAt: Date

    public init(requestID: String,
                conversationID: String,
                senderID: String,
                decision: DecisionRecord,
                recordedAt: Date = Date()) {
        self.requestID = requestID
        self.conversationID = conversationID
        self.senderID = senderID
        self.decision = decision
        self.recordedAt = recordedAt
    }
}

/// Something the rest of the platform needs to know about, published at least once.
public struct OutboxEvent: Codable, Equatable {
    public enum Kind: String, Codable {
        case decision
        case report
        case block
        /// A Tier 3 adjudication of an earlier decision. Published as its own event because the
        /// message has already been delivered by the time it arrives — the platform has to act
        /// on it (retract, warn, raise risk) rather than simply record it.
        case adjudication
    }

    public var id: String
    public var requestID: String
    public var kind: Kind
    /// For a decision, the action taken. For a recipient signal, the sender it concerns.
    public var subject: String
    public var occurredAt: Date
    public var delivered: Bool

    public init(id: String = UUID().uuidString,
                requestID: String,
                kind: Kind,
                subject: String,
                occurredAt: Date = Date(),
                delivered: Bool = false) {
        self.id = id
        self.requestID = requestID
        self.kind = kind
        self.subject = subject
        self.occurredAt = occurredAt
        self.delivered = delivered
    }
}

public enum DecisionStoreError: Error, CustomStringConvertible {
    case notWritable(String)

    public var description: String {
        switch self {
        case .notWritable(let detail):
            return "decision store is not writable: \(detail)"
        }
    }
}

public protocol DecisionStore: AnyObject {

    /// Persist a decision and its outbox event together, or neither.
    ///
    /// Throwing means the decision was not recorded. Callers must not treat the message as
    /// decided: an unrecorded decision cannot be appealed, audited or reconciled.
    func commit(_ envelope: DecisionEnvelope, event: OutboxEvent) throws

    /// Insert only if this `requestID` has not been stored. Returns the canonical envelope —
    /// the one already stored if a concurrent writer won, otherwise `envelope`.
    func commitIfAbsent(_ envelope: DecisionEnvelope, event: OutboxEvent) throws -> DecisionEnvelope

    /// Claim an idempotency key before evaluation. `acquired` means this process should evaluate;
    /// otherwise return the stored envelope (wait if it is still a reservation).
    func reserve(_ envelope: DecisionEnvelope) throws -> (acquired: Bool, envelope: DecisionEnvelope)

    /// Replace a reservation with the real decision and its outbox event. If another replica
    /// already finalised, returns theirs and does not overwrite.
    func finalize(_ envelope: DecisionEnvelope, event: OutboxEvent) throws -> DecisionEnvelope

    /// Persist a recipient signal's outbox event. Reports and blocks change enforcement
    /// posture, so they are durable for the same reasons decisions are.
    func commit(event: OutboxEvent) throws

    /// The stored decision for an idempotency key, if this request was already decided.
    func decision(forRequestID requestID: String) -> DecisionEnvelope?

    /// Events not yet published, oldest first.
    func pendingEvents(limit: Int) -> [OutboxEvent]

    func markDelivered(_ ids: [String]) throws

    /// Events inside a window, oldest first. Used to rebuild behavioural state after a restart.
    func events(since: Date) -> [OutboxEvent]

    var committedDecisions: Int { get }
}

// MARK: - In-memory

/// The default. Correct for the app and for tests, and explicitly not durable — which is why a
/// deployment is expected to install something else and why startup reports which one is active.
public final class InMemoryDecisionStore: DecisionStore {

    private let lock = NSLock()
    private var byRequest: [String: DecisionEnvelope] = [:]
    private var order: [String] = []
    private var outbox: [OutboxEvent] = []
    private let maxDecisions: Int

    public init(maxDecisions: Int = 50_000) {
        self.maxDecisions = maxDecisions
    }

    public func commit(_ envelope: DecisionEnvelope, event: OutboxEvent) throws {
        _ = try commitIfAbsent(envelope, event: event)
    }

    public func commitIfAbsent(_ envelope: DecisionEnvelope, event: OutboxEvent) throws -> DecisionEnvelope {
        lock.lock()
        defer { lock.unlock() }
        if let existing = byRequest[envelope.requestID] { return existing }
        if byRequest[envelope.requestID] == nil {
            order.append(envelope.requestID)
            if order.count > maxDecisions {
                let evicted = order.removeFirst()
                byRequest.removeValue(forKey: evicted)
            }
        }
        byRequest[envelope.requestID] = envelope
        outbox.append(event)
        return envelope
    }

    public func reserve(_ envelope: DecisionEnvelope) throws -> (acquired: Bool, envelope: DecisionEnvelope) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = byRequest[envelope.requestID] {
            if existing.decision.isReservation,
               Date().timeIntervalSince(existing.recordedAt) > 15 {
                byRequest[envelope.requestID] = envelope
                return (true, envelope)
            }
            return (false, existing)
        }
        if order.count >= maxDecisions {
            let evicted = order.removeFirst()
            byRequest.removeValue(forKey: evicted)
        }
        order.append(envelope.requestID)
        byRequest[envelope.requestID] = envelope
        return (true, envelope)
    }

    public func finalize(_ envelope: DecisionEnvelope, event: OutboxEvent) throws -> DecisionEnvelope {
        lock.lock()
        defer { lock.unlock() }
        if let existing = byRequest[envelope.requestID], !existing.decision.isReservation {
            return existing
        }
        if byRequest[envelope.requestID] == nil {
            order.append(envelope.requestID)
            if order.count > maxDecisions {
                let evicted = order.removeFirst()
                byRequest.removeValue(forKey: evicted)
            }
        }
        byRequest[envelope.requestID] = envelope
        outbox.append(event)
        return envelope
    }

    public func commit(event: OutboxEvent) throws {
        lock.lock()
        outbox.append(event)
        lock.unlock()
    }

    public func decision(forRequestID requestID: String) -> DecisionEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return byRequest[requestID]
    }

    public func pendingEvents(limit: Int) -> [OutboxEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(outbox.filter { !$0.delivered }.prefix(limit))
    }

    public func markDelivered(_ ids: [String]) throws {
        let set = Set(ids)
        lock.lock()
        for i in outbox.indices where set.contains(outbox[i].id) { outbox[i].delivered = true }
        lock.unlock()
    }

    public func events(since: Date) -> [OutboxEvent] {
        lock.lock()
        defer { lock.unlock() }
        return outbox.filter { $0.occurredAt >= since }
    }

    public var committedDecisions: Int {
        lock.lock()
        defer { lock.unlock() }
        return byRequest.count
    }
}

// MARK: - Append-only file

/// A durable store with no external dependency: one JSON object per line, appended and flushed.
///
/// This exists so that "decisions survive a restart" is true out of the box rather than
/// contingent on a database being provisioned first. It is a single-writer store — one process
/// per log file — because concurrent appends from multiple processes can interleave mid-line.
/// A deployment that outgrows that implements `DecisionStore` against its own database; nothing
/// above this line changes when it does.
public final class FileDecisionStore: DecisionStore {

    private struct Line: Codable {
        var envelope: DecisionEnvelope?
        var event: OutboxEvent
    }

    private let lock = NSLock()
    private let handle: FileHandle
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var byRequest: [String: DecisionEnvelope] = [:]
    private var outbox: [OutboxEvent] = []

    public init(path: String) throws {
        encoder.outputFormatting = []
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) {
            guard fm.createFile(atPath: path, contents: nil) else {
                throw DecisionStoreError.notWritable(path)
            }
        }
        guard let h = FileHandle(forUpdatingAtPath: path) else {
            throw DecisionStoreError.notWritable(path)
        }
        self.handle = h

        // Replay what is already there, so the index and the outbox reflect history rather
        // than only what this process has written.
        if let data = fm.contents(atPath: path) {
            for raw in data.split(separator: UInt8(ascii: "\n")) where !raw.isEmpty {
                guard let line = try? decoder.decode(Line.self, from: Data(raw)) else { continue }
                if let envelope = line.envelope { byRequest[envelope.requestID] = envelope }
                outbox.append(line.event)
            }
        }
        handle.seekToEndOfFile()
    }

    deinit { try? handle.close() }

    private func appendLocked(_ line: Line) throws {
        guard var data = try? encoder.encode(line) else {
            throw DecisionStoreError.notWritable("encoding failed")
        }
        data.append(UInt8(ascii: "\n"))
        handle.write(data)
        // Flush before returning. Without this a decision is "recorded" only in a page cache
        // and a power loss reverts it, which is precisely the case durability is claimed for.
        handle.synchronizeFile()
    }

    public func commit(_ envelope: DecisionEnvelope, event: OutboxEvent) throws {
        _ = try commitIfAbsent(envelope, event: event)
    }

    public func commitIfAbsent(_ envelope: DecisionEnvelope, event: OutboxEvent) throws -> DecisionEnvelope {
        lock.lock()
        defer { lock.unlock() }
        if let existing = byRequest[envelope.requestID] { return existing }
        try appendLocked(Line(envelope: envelope, event: event))
        byRequest[envelope.requestID] = envelope
        outbox.append(event)
        return envelope
    }

    public func reserve(_ envelope: DecisionEnvelope) throws -> (acquired: Bool, envelope: DecisionEnvelope) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = byRequest[envelope.requestID] {
            if existing.decision.isReservation,
               Date().timeIntervalSince(existing.recordedAt) > 15 {
                try appendLocked(Line(envelope: envelope, event: Self.reservationAck(envelope.requestID)))
                byRequest[envelope.requestID] = envelope
                return (true, envelope)
            }
            return (false, existing)
        }
        try appendLocked(Line(envelope: envelope, event: Self.reservationAck(envelope.requestID)))
        byRequest[envelope.requestID] = envelope
        return (true, envelope)
    }

    public func finalize(_ envelope: DecisionEnvelope, event: OutboxEvent) throws -> DecisionEnvelope {
        lock.lock()
        defer { lock.unlock() }
        if let existing = byRequest[envelope.requestID], !existing.decision.isReservation {
            return existing
        }
        try appendLocked(Line(envelope: envelope, event: event))
        byRequest[envelope.requestID] = envelope
        outbox.append(event)
        return envelope
    }

    private static func reservationAck(_ requestID: String) -> OutboxEvent {
        OutboxEvent(
            id: requestID + "#reserve",
            requestID: requestID,
            kind: .decision,
            subject: DecisionRecord.reservationAction,
            delivered: true
        )
    }

    public func commit(event: OutboxEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        try appendLocked(Line(envelope: nil, event: event))
        outbox.append(event)
    }

    public func decision(forRequestID requestID: String) -> DecisionEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return byRequest[requestID]
    }

    public func pendingEvents(limit: Int) -> [OutboxEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(outbox.filter { !$0.delivered }.prefix(limit))
    }

    public func markDelivered(_ ids: [String]) throws {
        // Delivery is recorded as a new line rather than by rewriting history: an append-only
        // log that gets edited in place is no longer an audit trail.
        let set = Set(ids)
        lock.lock()
        defer { lock.unlock() }
        for i in outbox.indices where set.contains(outbox[i].id) && !outbox[i].delivered {
            outbox[i].delivered = true
            var settled = outbox[i]
            settled.delivered = true
            try appendLocked(Line(envelope: nil, event: settled))
        }
    }

    public func events(since: Date) -> [OutboxEvent] {
        lock.lock()
        defer { lock.unlock() }
        return outbox.filter { $0.occurredAt >= since }.sorted { $0.occurredAt < $1.occurredAt }
    }

    public var committedDecisions: Int {
        lock.lock()
        defer { lock.unlock() }
        return byRequest.count
    }
}

/// Serialises work that shares an idempotency key inside one process.
final class KeyedLock {
    private let cond = NSCondition()
    private var held: Set<String> = []

    func with<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
        cond.lock()
        while held.contains(key) { cond.wait() }
        held.insert(key)
        cond.unlock()
        defer {
            cond.lock()
            held.remove(key)
            cond.broadcast()
            cond.unlock()
        }
        return try body()
    }
}
