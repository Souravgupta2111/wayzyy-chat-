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

    private struct Event {
        let at: Date
        let conversation: String
        let safetyScore: Double
        let routedForSafety: Bool
        let acted: Bool
    }

    private struct SenderState {
        var events: [Event] = []
        var reports: [Date] = []
        var blocks: [Date] = []
    }

    private let lock = NSLock()
    private var senders: [String: SenderState] = [:]

    private let maxSenders = 20_000

    func observe(
        sender: String,
        conversation: String,
        safetyScore: Double,
        routedForSafety: Bool,
        acted: Bool,
        at now: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        if senders[sender] == nil, senders.count >= maxSenders { evictOldestLocked() }
        var state = senders[sender] ?? SenderState()
        state.events.append(Event(at: now, conversation: conversation,
                                  safetyScore: safetyScore,
                                  routedForSafety: routedForSafety, acted: acted))
        prune(&state, now: now)
        senders[sender] = state
    }

    func recordReport(against sender: String, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var state = senders[sender] ?? SenderState()
        state.reports.append(now)
        prune(&state, now: now)
        senders[sender] = state
    }

    func recordBlock(of sender: String, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var state = senders[sender] ?? SenderState()
        state.blocks.append(now)
        prune(&state, now: now)
        senders[sender] = state
    }

    func risk(for sender: String, conversation: String, at now: Date = Date()) -> ActorRisk {
        lock.lock()
        defer { lock.unlock() }
        guard var state = senders[sender] else { return ActorRisk() }
        prune(&state, now: now)
        senders[sender] = state

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

    private func prune(_ state: inout SenderState, now: Date) {
        let cutoff = now.addingTimeInterval(-Self.window)
        state.events.removeAll { $0.at < cutoff }
        state.reports.removeAll { $0 < cutoff }
        state.blocks.removeAll { $0 < cutoff }
    }

    private func evictOldestLocked() {
        let oldest = senders.min { a, b in
            (a.value.events.last?.at ?? .distantPast) < (b.value.events.last?.at ?? .distantPast)
        }
        if let key = oldest?.key { senders.removeValue(forKey: key) }
    }

    func reset(sender: String) {
        lock.lock()
        senders.removeValue(forKey: sender)
        lock.unlock()
    }

    func resetAll() {
        lock.lock()
        senders.removeAll()
        lock.unlock()
    }

    var trackedSenderCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return senders.count
    }
}
