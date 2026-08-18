// Storage seam for conversation buffers.
//
// Why this has to be pluggable
// ────────────────────────────
// A conversation buffer is the engine's short-term memory of a *thread*: the last few messages
// from one sender in one conversation, inside a 15-minute window. It exists because the most
// effective attacks are the ones no single message reveals — a phone number split across four
// messages, a positional cue established in one and redeemed in the next.
//
// In one process a dictionary is exactly right. Behind a load balancer it is worse than the
// actor-signal case, because the attack it defends against is *specifically* the one that
// spreads across requests. With N replicas and no shared store, four drip-fed fragments land on
// four different pods and none of them holds more than one fragment, so the assembly that would
// have caught it never happens. The detection does not degrade gracefully — it disappears, and
// it disappears exactly for the families the corpus already shows are thinnest.
//
// The split is the same one used for actor signals, and for the same reason: the backend owns
// *storage only*. The window, the depth, the eviction policy and every decision about what the
// buffered text means stay in `ConversationBuffers`. A deployment can move the bytes to Redis
// without acquiring the ability to change what the engine concludes from them.
//
// Mutation is a single `mutate(key:_:)` closure rather than a read followed by a write, because
// against a shared store those are two round trips and a concurrent append between them silently
// drops a message — which in this design means silently dropping the evidence that an attack is
// in progress.

import Foundation

/// One sender's recent messages in one conversation. Codable so a remote backend is a get/set.
public struct ConversationBufferSnapshot: Codable, Equatable {

    public struct Message: Codable, Equatable {
        public var text: String
        public var at: Date

        public init(text: String, at: Date) {
            self.text = text
            self.at = at
        }
    }

    public var messages: [Message] = []

    public init() {}

    /// Newest-last, capped to `depth`, with anything older than the window dropped.
    mutating func trim(depth: Int, cutoff: Date) {
        messages.removeAll { $0.at < cutoff }
        if messages.count > depth { messages.removeFirst(messages.count - depth) }
    }

    var isEmpty: Bool { messages.isEmpty }

    var newest: Date? { messages.last?.at }
}

public protocol ConversationBufferBackend: AnyObject {

    func snapshot(key: String) -> ConversationBufferSnapshot?

    /// Read, modify and write as one atomic operation. An implementation backed by a network
    /// store must make this genuinely atomic: a lost append is a lost attack fragment.
    func mutate(key: String, _ body: (inout ConversationBufferSnapshot) -> Void)

    func remove(key: String)
    func removeAll()

    /// Drop conversations whose newest message predates the cutoff, then, if still above
    /// `maxConversations`, the least recently active. Eviction is the backend's job because
    /// only the backend knows how its storage expires; the *policy* is supplied by the caller.
    func evict(before cutoff: Date, maxConversations: Int)

    var trackedCount: Int { get }
}

/// The default: in-process, lock-guarded, bounded. Correct for a single replica and for the app.
public final class InMemoryConversationBufferBackend: ConversationBufferBackend {

    private let lock = NSLock()
    private var storage: [String: ConversationBufferSnapshot] = [:]

    public init() {}

    public func snapshot(key: String) -> ConversationBufferSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func mutate(key: String, _ body: (inout ConversationBufferSnapshot) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = storage[key] ?? ConversationBufferSnapshot()
        body(&snapshot)
        if snapshot.isEmpty { storage.removeValue(forKey: key) } else { storage[key] = snapshot }
    }

    public func remove(key: String) {
        lock.lock()
        storage.removeValue(forKey: key)
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }

    public func evict(before cutoff: Date, maxConversations: Int) {
        lock.lock()
        defer { lock.unlock() }
        storage = storage.filter { _, snapshot in
            guard let newest = snapshot.newest else { return false }
            return newest >= cutoff
        }
        guard storage.count > maxConversations else { return }
        let ordered = storage
            .map { (key: $0.key, at: $0.value.newest ?? .distantPast) }
            .sorted { $0.at < $1.at }
        for entry in ordered.prefix(storage.count - maxConversations) {
            storage.removeValue(forKey: entry.key)
        }
    }

    public var trackedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}
