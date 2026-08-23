
import Foundation

public struct ActorSignalSnapshot: Codable, Equatable {

    public struct Event: Codable, Equatable {
        public var at: Date
        public var conversation: String
        public var safetyScore: Double
        public var routedForSafety: Bool
        public var acted: Bool

        public init(at: Date, conversation: String, safetyScore: Double,
                    routedForSafety: Bool, acted: Bool) {
            self.at = at
            self.conversation = conversation
            self.safetyScore = safetyScore
            self.routedForSafety = routedForSafety
            self.acted = acted
        }
    }

    public var events: [Event] = []
    public var reports: [Date] = []
    public var blocks: [Date] = []
    public var platformPriors: Int = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case events, reports, blocks, platformPriors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decodeIfPresent([Event].self, forKey: .events) ?? []
        reports = try c.decodeIfPresent([Date].self, forKey: .reports) ?? []
        blocks = try c.decodeIfPresent([Date].self, forKey: .blocks) ?? []
        platformPriors = try c.decodeIfPresent(Int.self, forKey: .platformPriors) ?? 0
    }

    mutating func prune(before cutoff: Date) {
        events.removeAll { $0.at < cutoff }
        reports.removeAll { $0 < cutoff }
        blocks.removeAll { $0 < cutoff }
    }

    var isEmpty: Bool {
        events.isEmpty && reports.isEmpty && blocks.isEmpty && platformPriors <= 0
    }
}

public protocol ActorSignalBackend: AnyObject {

    func snapshot(sender: String) -> ActorSignalSnapshot?

    func mutate(sender: String, _ body: (inout ActorSignalSnapshot) -> Void)

    func remove(sender: String)
    func removeAll()
    var trackedSenderCount: Int { get }
}

public final class InMemoryActorSignalBackend: ActorSignalBackend {

    private let lock = NSLock()
    private var senders: [String: ActorSignalSnapshot] = [:]
    private let maxSenders: Int

    public init(maxSenders: Int = 20_000) {
        self.maxSenders = maxSenders
    }

    public func snapshot(sender: String) -> ActorSignalSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return senders[sender]
    }

    public func mutate(sender: String, _ body: (inout ActorSignalSnapshot) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if senders[sender] == nil, senders.count >= maxSenders { evictOldestLocked() }
        var state = senders[sender] ?? ActorSignalSnapshot()
        body(&state)
        if state.isEmpty { senders.removeValue(forKey: sender) } else { senders[sender] = state }
    }

    public func remove(sender: String) {
        lock.lock()
        senders.removeValue(forKey: sender)
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        senders.removeAll()
        lock.unlock()
    }

    public var trackedSenderCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return senders.count
    }

    private func evictOldestLocked() {
        let oldest = senders.min { a, b in
            (a.value.events.last?.at ?? .distantPast) < (b.value.events.last?.at ?? .distantPast)
        }
        if let key = oldest?.key { senders.removeValue(forKey: key) }
    }
}
