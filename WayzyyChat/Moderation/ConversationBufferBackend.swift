
import Foundation

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

    mutating func trim(depth: Int, cutoff: Date) {
        messages.removeAll { $0.at < cutoff }
        if messages.count > depth { messages.removeFirst(messages.count - depth) }
    }

    var isEmpty: Bool { messages.isEmpty }

    var newest: Date? { messages.last?.at }
}

public protocol ConversationBufferBackend: AnyObject {

    func snapshot(key: String) -> ConversationBufferSnapshot?

    func mutate(key: String, _ body: (inout ConversationBufferSnapshot) -> Void)

    func remove(key: String)
    func removeAll()

    func evict(before cutoff: Date, maxConversations: Int)

    var trackedCount: Int { get }
}

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
