// Bounded, locked per-conversation message windows used for cross-message assembly.

import Foundation

final class ConversationBuffers {

    private struct Buffered {
        let text: String
        let at: Date
    }

    private var storage: [String: [Buffered]] = [:]
    private let lock = NSLock()

    private let window: TimeInterval
    private let depth: Int
    private let maxConversations: Int

    init(window: TimeInterval = 15 * 60, depth: Int = 14, maxConversations: Int = 512) {
        self.window = window
        self.depth = depth
        self.maxConversations = maxConversations
    }

    private func key(_ actor: ActorContext) -> String {
        "\(actor.conversationID)|\(actor.senderID)"
    }

    func remember(_ text: String, actor: ActorContext) {
        lock.lock()
        defer { lock.unlock() }
        let k = key(actor)
        var list = storage[k] ?? []
        list.append(Buffered(text: text, at: Date()))
        if list.count > depth { list.removeFirst(list.count - depth) }
        storage[k] = list
        if storage.count > maxConversations { evictLocked() }
    }

    func recent(_ actor: ActorContext) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-window)
        return (storage[key(actor)] ?? [])
            .filter { $0.at >= cutoff }
            .map(\.text)
    }

    func reset(actor: ActorContext) {
        lock.lock()
        defer { lock.unlock() }
        storage[key(actor)] = nil
    }

    func consume(actor: ActorContext) {
        reset(actor: actor)
    }

    var trackedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    private func evictLocked() {
        let cutoff = Date().addingTimeInterval(-window)
        storage = storage.filter { _, list in
            guard let newest = list.last else { return false }
            return newest.at >= cutoff
        }
        guard storage.count > maxConversations else { return }
        let ordered = storage
            .map { (key: $0.key, at: $0.value.last?.at ?? .distantPast) }
            .sorted { $0.at < $1.at }
        for entry in ordered.prefix(storage.count - maxConversations) {
            storage.removeValue(forKey: entry.key)
        }
    }
}
