// Per-conversation message windows used for cross-message assembly.
//
// This type owns the *policy* — how long a message stays relevant, how many are kept, when a
// conversation is evicted — and delegates storage to a `ConversationBufferBackend`. See that
// file for why the storage has to be replaceable: the attacks these buffers exist to catch are
// precisely the ones that spread across requests, so per-replica buffers lose them entirely.

import Foundation

final class ConversationBuffers {

    private let backend: ConversationBufferBackend

    private let window: TimeInterval
    private let depth: Int
    private let maxConversations: Int

    init(window: TimeInterval = 15 * 60,
         depth: Int = 14,
         maxConversations: Int = 512,
         backend: ConversationBufferBackend = InMemoryConversationBufferBackend()) {
        self.window = window
        self.depth = depth
        self.maxConversations = maxConversations
        self.backend = backend
    }

    /// Keyed by conversation *and* sender: two people in one thread have separate buffers,
    /// because assembling one person's fragments out of another's messages would invent
    /// evidence that nobody produced.
    private func key(_ actor: ActorContext) -> String {
        "\(actor.conversationID)|\(actor.senderID)"
    }

    private var cutoff: Date { Date().addingTimeInterval(-window) }

    func remember(_ text: String, actor: ActorContext) {
        let now = Date()
        backend.mutate(key: key(actor)) { [depth, window] snapshot in
            snapshot.messages.append(ConversationBufferSnapshot.Message(text: text, at: now))
            snapshot.trim(depth: depth, cutoff: now.addingTimeInterval(-window))
        }
        backend.evict(before: cutoff, maxConversations: maxConversations)
    }

    func recent(_ actor: ActorContext) -> [String] {
        // Filtered on read as well as on write: a message that has aged out of the window must
        // not contribute to an assembly just because the conversation went quiet.
        let cutoff = self.cutoff
        return (backend.snapshot(key: key(actor))?.messages ?? [])
            .filter { $0.at >= cutoff }
            .map(\.text)
    }

    func reset(actor: ActorContext) {
        backend.remove(key: key(actor))
    }

    func consume(actor: ActorContext) {
        reset(actor: actor)
    }

    var trackedCount: Int { backend.trackedCount }

    /// For startup reporting: which storage is actually installed.
    var backendForDiagnostics: ConversationBufferBackend { backend }
}
