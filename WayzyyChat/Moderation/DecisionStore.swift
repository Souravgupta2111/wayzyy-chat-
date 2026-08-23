
import Foundation

public struct DecisionEnvelope: Codable, Equatable {
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

public struct OutboxEvent: Codable, Equatable {
    public enum Kind: String, Codable {
        case decision
        case report
        case block
        case adjudication
    }

    public var id: String
    public var requestID: String
    public var kind: Kind
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

    func commit(_ envelope: DecisionEnvelope, event: OutboxEvent) throws

    func commitIfAbsent(_ envelope: DecisionEnvelope, event: OutboxEvent) throws -> DecisionEnvelope

    func reserve(_ envelope: DecisionEnvelope) throws -> (acquired: Bool, envelope: DecisionEnvelope)

    func finalize(_ envelope: DecisionEnvelope, event: OutboxEvent) throws -> DecisionEnvelope

    func commit(event: OutboxEvent) throws

    func decision(forRequestID requestID: String) -> DecisionEnvelope?

    func pendingEvents(limit: Int) -> [OutboxEvent]

    func markDelivered(_ ids: [String]) throws

    func events(since: Date) -> [OutboxEvent]

    var committedDecisions: Int { get }
}


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
