// Storage seam for actor signals.
//
// Why this has to be pluggable
// ────────────────────────────
// Actor signals are the engine's only memory of a *person* rather than a message: how many
// reports they have received, how many people blocked them, how many sub-threshold safety hits
// they have accumulated in the last 24 hours. In one process, a dictionary is exactly right.
//
// Behind a load balancer it is wrong, and wrong in the direction that favours the attacker.
// With N replicas and no shared store, each pod sees roughly 1/N of a sender's history, so the
// escalation thresholds — three sub-threshold hits, or two after a report — are effectively
// multiplied by N. A sender who would escalate after three messages instead needs three
// messages *on the same pod*. Worse, a report recorded on pod A is invisible to pod B, so the
// evidence a recipient just supplied does not exist for the next message they receive.
//
// The split here is deliberate: the backend owns *storage only*, and `ActorSignalStore` keeps
// all of the risk arithmetic and every threshold. A deployment can therefore move state to
// Redis or Postgres without acquiring the ability to change what the numbers mean.
//
// Mutation is expressed as `mutate(sender:_:)` rather than load-then-store because with a
// shared backend those are two round trips and a concurrent update between them silently loses
// events. Making atomicity part of the protocol lets a Redis implementation satisfy it with a
// Lua script or WATCH/MULTI, instead of leaving a lost-update race in every caller.

import Foundation

/// Serialisable per-sender state. Codable so a remote backend is a JSON get/set.
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
    /// Floor from the platform user table, replicated across pods.
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

    /// Drop everything outside the window. Applied by the store on every access so a backend
    /// cannot grow without bound and cannot serve stale evidence.
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

    /// Read a sender's state. Absent senders read as nil, not as an error.
    func snapshot(sender: String) -> ActorSignalSnapshot?

    /// Read, modify and write as one atomic operation.
    ///
    /// Implementations backed by a network store must make this genuinely atomic. A
    /// load-modify-store built from two independent round trips drops concurrent reports,
    /// which is precisely the evidence the system can least afford to lose.
    func mutate(sender: String, _ body: (inout ActorSignalSnapshot) -> Void)

    func remove(sender: String)
    func removeAll()
    var trackedSenderCount: Int { get }
}

/// The default: in-process, lock-guarded, bounded. Correct for a single replica and for the app.
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
        // Pruning can empty a snapshot; dropping it keeps the map from filling with husks.
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
