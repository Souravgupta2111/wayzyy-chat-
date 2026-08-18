// Per-conversation trust/stage/priors set by the platform backend, not by a chat client.
//
// `POST /v1/moderate` ignores `stage`. A patched phone that reaches the service cannot pick
// `checkedIn` to loosen thresholds. The Edge Function writes context from the booking row.

import Foundation

public struct ConversationContextSnapshot: Codable, Equatable {
    public var stage: String?
    public var trust: String?
    public var priorViolations: Int = 0

    public init(stage: String? = nil, trust: String? = nil, priorViolations: Int = 0) {
        self.stage = stage
        self.trust = trust
        self.priorViolations = priorViolations
    }

    var isEmpty: Bool {
        (stage == nil || stage?.isEmpty == true)
            && (trust == nil || trust?.isEmpty == true)
            && priorViolations <= 0
    }
}

public protocol ConversationContextBackend: AnyObject {
    func snapshot(conversationID: String) -> ConversationContextSnapshot?
    func mutate(conversationID: String, _ body: (inout ConversationContextSnapshot) -> Void)
    func remove(conversationID: String)
}

public final class InMemoryConversationContextBackend: ConversationContextBackend {
    private let lock = NSLock()
    private var storage: [String: ConversationContextSnapshot] = [:]

    public init() {}

    public func snapshot(conversationID: String) -> ConversationContextSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return storage[conversationID]
    }

    public func mutate(conversationID: String, _ body: (inout ConversationContextSnapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var state = storage[conversationID] ?? ConversationContextSnapshot()
        body(&state)
        if state.isEmpty { storage.removeValue(forKey: conversationID) }
        else { storage[conversationID] = state }
    }

    public func remove(conversationID: String) {
        lock.lock(); storage.removeValue(forKey: conversationID); lock.unlock()
    }
}

final class ConversationContextStore {
    private let backend: ConversationContextBackend

    init(backend: ConversationContextBackend = InMemoryConversationContextBackend()) {
        self.backend = backend
    }

    var backendForDiagnostics: ConversationContextBackend { backend }

    func snapshot(conversationID: String) -> ConversationContextSnapshot? {
        backend.snapshot(conversationID: conversationID)
    }

    func apply(conversationID: String,
               stage: String?,
               trust: String?,
               priorViolations: Int?) {
        backend.mutate(conversationID: conversationID) { state in
            if let stage, !stage.isEmpty { state.stage = stage }
            if let trust, !trust.isEmpty { state.trust = trust }
            if let priorViolations {
                state.priorViolations = max(state.priorViolations, priorViolations)
            }
        }
    }
}
