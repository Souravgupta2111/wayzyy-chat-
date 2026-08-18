// Actor and behavioural signals over a 24-hour window: velocity, fan-out, reports and sub-threshold safety patterns.

import Foundation

struct ActorRisk {
    var messagesInWindow = 0
    var distinctConversations = 0
    var repeatTargetCount = 0
    var receivedReports = 0
    var blockEvents = 0
    var subThresholdSafetyHits = 0
    var escalating = false

    var composite: Double {
        var r = 0.0
        r += Swift.min(Double(receivedReports) * 0.30, 0.60)
        r += Swift.min(Double(blockEvents) * 0.20, 0.40)
        r += Swift.min(Double(subThresholdSafetyHits) * 0.12, 0.36)
        r += Swift.min(Double(distinctConversations) / 40.0, 0.20)
        r += Swift.min(Double(messagesInWindow) / 400.0, 0.10)
        return Swift.min(r, 1.0)
    }

    var isElevated: Bool { composite >= 0.35 }
}

final class ActorSignalStore {

    static let window: TimeInterval = 24 * 3_600
    static let patternThreshold = 3
    static let patternThresholdAfterReport = 2

    /// Storage only. Every threshold and all of the risk arithmetic stays in this type, so
    /// swapping in a shared backend cannot change what the numbers mean.
    private let backend: ActorSignalBackend

    init(backend: ActorSignalBackend = InMemoryActorSignalBackend()) {
        self.backend = backend
    }

    func observe(
        sender: String,
        conversation: String,
        safetyScore: Double,
        routedForSafety: Bool,
        acted: Bool,
        at now: Date = Date()
    ) {
        backend.mutate(sender: sender) { state in
            state.events.append(ActorSignalSnapshot.Event(
                at: now, conversation: conversation, safetyScore: safetyScore,
                routedForSafety: routedForSafety, acted: acted))
            state.prune(before: now.addingTimeInterval(-Self.window))
        }
    }

    func recordReport(against sender: String, at now: Date = Date()) {
        backend.mutate(sender: sender) { state in
            state.reports.append(now)
            state.prune(before: now.addingTimeInterval(-Self.window))
        }
    }

    func recordBlock(of sender: String, at now: Date = Date()) {
        backend.mutate(sender: sender) { state in
            state.blocks.append(now)
            state.prune(before: now.addingTimeInterval(-Self.window))
        }
    }

    /// Persist DB-backed violation counts so a replica that has not seen this sender still clamps.
    func notePlatformPriors(sender: String, count: Int) {
        guard count > 0 else { return }
        backend.mutate(sender: sender) { state in
            state.platformPriors = max(state.platformPriors, count)
        }
    }

    func platformPriors(for sender: String) -> Int {
        max(0, backend.snapshot(sender: sender)?.platformPriors ?? 0)
    }

    func risk(for sender: String, conversation: String, at now: Date = Date()) -> ActorRisk {
        guard var state = backend.snapshot(sender: sender) else { return ActorRisk() }
        // Prune on read as well as write: expired evidence must not count towards a threshold
        // just because the sender has been quiet since.
        state.prune(before: now.addingTimeInterval(-Self.window))

        var risk = ActorRisk()
        risk.messagesInWindow = state.events.count
        risk.distinctConversations = Set(state.events.map(\.conversation)).count
        risk.receivedReports = state.reports.count
        risk.blockEvents = state.blocks.count

        let here = state.events.filter { $0.conversation == conversation }
        risk.repeatTargetCount = here.count

        let subThreshold = here.filter { $0.routedForSafety && !$0.acted }
        risk.subThresholdSafetyHits = subThreshold.count

        let bar = risk.receivedReports > 0
            ? Self.patternThresholdAfterReport
            : Self.patternThreshold
        risk.escalating = subThreshold.count >= bar
        return risk
    }

    /// For startup reporting only: which storage is actually installed. A deployment that
    /// believes it moved actor state to a shared store and did not should be able to see that.
    var backendForDiagnostics: ActorSignalBackend { backend }

    func reset(sender: String) { backend.remove(sender: sender) }

    func resetAll() { backend.removeAll() }

    var trackedSenderCount: Int { backend.trackedSenderCount }
}
