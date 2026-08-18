// Observable chat state: send path, delivery status, provisional holds, background escalation and the moderation queue.

import Foundation
import SwiftUI

enum DeliveryStatus: String {
    case sending, sent, delivered, read
    case withheld
    case underReview
    case checking

    var glyph: String {
        switch self {
        case .sending:     return "clock"
        case .sent:        return "checkmark"
        case .delivered:   return "checkmark.circle"
        case .read:        return "checkmark.circle.fill"
        case .withheld:    return "exclamationmark.shield.fill"
        case .underReview: return "clock.badge.questionmark"
        case .checking:    return "hourglass"
        }
    }

    var textGlyph: String {
        switch self {
        case .sending:     return "◌"
        case .sent:        return "✓"
        case .delivered:   return "✓✓"
        case .read:        return "✓✓"
        case .withheld:    return "⊘"
        case .underReview: return "◷"
        case .checking:    return "⧗"
        }
    }
}

struct ChatMessage: Identifiable {
    let id: UUID
    var text: String
    var isOutgoing: Bool
    var timestamp: Date
    var verdict: Verdict?
    var status: DeliveryStatus
    var revealed: Bool = false
    var isSystemNotice: Bool = false

    init(
        text: String,
        isOutgoing: Bool,
        timestamp: Date,
        verdict: Verdict? = nil,
        status: DeliveryStatus = .read,
        isSystemNotice: Bool = false
    ) {
        self.id = UUID()
        self.text = text
        self.isOutgoing = isOutgoing
        self.timestamp = timestamp
        self.verdict = verdict
        self.status = status
        self.isSystemNotice = isSystemNotice
    }

    var displayText: String {
        guard let verdict, !revealed else { return text }
        switch verdict.action {
        case .mask:  return verdict.maskedText
        case .allow, .hint: return text
        case .warn, .block, .review: return verdict.maskedText
        }
    }

    var wasModerated: Bool {
        guard let v = verdict else { return false }
        return v.action != .allow && v.action != .hint
    }
}

struct Conversation: Identifiable {
    let id: UUID
    var name: String
    var propertyName: String
    var bookingRef: String
    var initials: String
    var isHost: Bool
    var messages: [ChatMessage]
    var trust: TrustTier
    var stage: BookingStage
    var priorViolations: Int
    var unread: Int
    var isOnline: Bool

    init(
        name: String,
        propertyName: String,
        bookingRef: String,
        initials: String,
        isHost: Bool,
        messages: [ChatMessage] = [],
        trust: TrustTier = .standard,
        stage: BookingStage = .inquiry,
        priorViolations: Int = 0,
        unread: Int = 0,
        isOnline: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.propertyName = propertyName
        self.bookingRef = bookingRef
        self.initials = initials
        self.isHost = isHost
        self.messages = messages
        self.trust = trust
        self.stage = stage
        self.priorViolations = priorViolations
        self.unread = unread
        self.isOnline = isOnline
    }

    var subtitle: String { "\(propertyName) · \(bookingRef)" }

    var lastMessage: ChatMessage? {
        messages.last { !$0.isSystemNotice }
    }

    func actorContext(senderID: String) -> ActorContext {
        ActorContext(
            trust: trust,
            stage: stage,
            priorViolations: priorViolations,
            conversationID: id.uuidString,
            senderID: senderID
        )
    }
}

struct QueueItem: Identifiable {
    let id = UUID()
    let conversationID: UUID
    let conversationName: String
    let text: String
    let verdict: Verdict
    let at: Date
    var resolution: Resolution? = nil

    enum Resolution: String {
        case upheld = "Upheld"
        case overturned = "Overturned"
    }
}

@MainActor
final class ChatStore: ObservableObject {

    @Published var conversations: [Conversation] = []
    @Published var queue: [QueueItem] = []
    @Published var trainingExamplesCollected: Int = 0
    @Published var suiteReport: SuiteReport? = nil
    @Published var isRunningSuite = false

    @Published var redTeamReport: RedTeamReport? = nil
    @Published var isRunningRedTeam = false
    @Published var comparison: ComparisonReport? = nil
    @Published var llmOutcome: BaselineOutcome? = nil
    @Published var llmProgress: String? = nil

    private let engine = ModerationEngine.shared

    /// Tier 3 follows adjudicator availability rather than a hardcoded default.
    ///
    /// Enabling it without a reachable model would promise adjudication that cannot happen;
    /// leaving it off when one *is* reachable discards the layer that resolves implication
    /// and, measurably, removes false positives on complaints. Either way the engine now
    /// fails closed on critical-severity content when no adjudicator exists, so this flag
    /// controls whether escalation runs — not whether safety holds.
    @Published var tier3Enabled = ModerationEngine.shared.tier3Available
    @Published var tier3Activity: String? = nil

    init() {
        engine.configureJudgeFromSecrets()
        if let restored = ChatPersistence.load() {
            conversations = restored
        } else {
            conversations = Self.seed()
            persist()
        }
    }

    private func persist() {
        ChatPersistence.save(conversations)
    }

    func resetToSeed() {
        ChatPersistence.reset()
        conversations = Self.seed()
        queue.removeAll()
        trainingExamplesCollected = 0
        persist()
    }

    @discardableResult
    func startConversation(
        name: String,
        property: String,
        isHost: Bool,
        trust: TrustTier,
        stage: BookingStage
    ) -> UUID {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "New contact" : trimmedName
        let trimmedProperty = property.trimmingCharacters(in: .whitespacesAndNewlines)

        let conversation = Conversation(
            name: finalName,
            propertyName: trimmedProperty.isEmpty ? "Unassigned listing" : trimmedProperty,
            bookingRef: "WZ-\(Int.random(in: 1000...9999))",
            initials: Self.initials(from: finalName),
            isHost: isHost,
            messages: [],
            trust: trust,
            stage: stage,
            priorViolations: 0,
            unread: 0,
            isOnline: Bool.random()
        )
        conversations.insert(conversation, at: 0)
        persist()
        return conversation.id
    }

    private static func initials(from name: String) -> String {
        let parts = name.split(separator: " ").compactMap(\.first)
        if parts.isEmpty { return "?" }
        if parts.count == 1 { return String(parts[0]).uppercased() }
        return String([parts[0], parts[1]]).uppercased()
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        queue.removeAll { $0.conversationID == id }
        persist()
    }

    func send(_ raw: String, in conversationID: UUID) -> Verdict? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let idx = conversations.firstIndex(where: { $0.id == conversationID })
        else { return nil }

        let actor = conversations[idx].actorContext(senderID: "me")
        let verdict = engine.evaluate(text, actor: actor)

        let willEscalate = tier3Enabled && engine.shouldEscalate(verdict)
        let holding = verdict.provisionalHold && willEscalate

        let status: DeliveryStatus
        switch verdict.action {
        case .allow, .hint: status = holding ? .checking : .delivered
        case .mask:         status = holding ? .checking : .delivered
        case .review:       status = .underReview
        case .warn, .block: status = .withheld
        }

        let message = ChatMessage(
            text: text,
            isOutgoing: true,
            timestamp: Date(),
            verdict: verdict,
            status: status
        )
        conversations[idx].messages.append(message)

        if !verdict.action.withholdsMessage {
            engine.remember(text, actor: actor)
        }
        defer { persist() }

        if let notice = Self.notice(for: verdict) {
            let recent = conversations[idx].messages.suffix(6)
            let alreadyExplained = recent.contains { $0.isSystemNotice && $0.text == notice }
            if !alreadyExplained {
                conversations[idx].messages.append(
                    ChatMessage(text: notice, isOutgoing: false, timestamp: Date(), isSystemNotice: true)
                )
            }
        }

        if verdict.action != .allow && verdict.action != .hint {
            queue.insert(
                QueueItem(
                    conversationID: conversationID,
                    conversationName: conversations[idx].name,
                    text: text,
                    verdict: verdict,
                    at: Date()
                ),
                at: 0
            )
        }

        if willEscalate {
            escalateInBackground(messageID: message.id, text: text, verdict: verdict, conversationID: conversationID)
        }
        if holding {
            scheduleHoldRelease(messageID: message.id, conversationID: conversationID)
        }

        return verdict
    }

    static let provisionalHoldTimeout: TimeInterval = 5.0

    private func scheduleHoldRelease(messageID: UUID, conversationID: UUID) {
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.provisionalHoldTimeout * 1_000_000_000)
            )
            guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
                  let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }),
                  conversations[ci].messages[mi].status == .checking
            else { return }

            conversations[ci].messages[mi].status = .underReview
            if var v = conversations[ci].messages[mi].verdict {
                v.reasonCodes.append("PROVISIONAL_HOLD_TIMEOUT")
                conversations[ci].messages[mi].verdict = v
                queue.insert(
                    QueueItem(
                        conversationID: conversationID,
                        conversationName: conversations[ci].name,
                        text: conversations[ci].messages[mi].text,
                        verdict: v,
                        at: Date()
                    ),
                    at: 0
                )
            }
            tier3Activity = nil
            persist()
        }
    }

    private func escalateInBackground(
        messageID: UUID,
        text: String,
        verdict: Verdict,
        conversationID: UUID
    ) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let actor = conversations[idx].actorContext(senderID: "me")

        Task { @MainActor in
            tier3Activity = "Escalating to \(SecretsStore.providerDescription)…"
            guard let (revised, judgement) = await engine.escalate(
                verdict: verdict, message: text, actor: actor
            ) else {
                tier3Activity = nil
                return
            }
            tier3Activity = nil

            guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
                  let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID })
            else { return }

            guard revised.action != verdict.action || verdict.provisionalHold else { return }

            conversations[ci].messages[mi].verdict = revised
            switch revised.action {
            case .allow, .hint: conversations[ci].messages[mi].status = .delivered
            case .mask:         conversations[ci].messages[mi].status = .delivered
            case .review:       conversations[ci].messages[mi].status = .underReview
            case .warn, .block: conversations[ci].messages[mi].status = .withheld
            }

            queue.insert(
                QueueItem(
                    conversationID: conversationID,
                    conversationName: conversations[ci].name,
                    text: text,
                    verdict: revised,
                    at: Date()
                ),
                at: 0
            )
        }
    }

    func hint(_ text: String, in conversationID: UUID) -> Verdict? {
        guard text.count >= 3,
              let convo = conversations.first(where: { $0.id == conversationID })
        else { return nil }
        let verdict = engine.hint(text, actor: convo.actorContext(senderID: "me"))
        return verdict.detections.isEmpty ? nil : verdict
    }

    func toggleReveal(messageID: UUID, in conversationID: UUID) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        conversations[ci].messages[mi].revealed.toggle()
    }

    func updateContext(conversationID: UUID, trust: TrustTier? = nil, stage: BookingStage? = nil) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        if let trust { conversations[idx].trust = trust }
        if let stage { conversations[idx].stage = stage }
        persist()
    }

    func markRead(conversationID: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationID }),
              conversations[idx].unread != 0
        else { return }
        conversations[idx].unread = 0
        persist()
    }

    // MARK: - Recipient controls
    //
    // Reports and blocks are the only label source in a design without a human review tier,
    // and a report also lowers the behavioural pattern bar from three sub-threshold hits to
    // two. They feed evidence forward; they never enforce on their own.

    /// The recipient reported this conversation's sender.
    func reportSender(in conversationID: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let actor = conversations[idx].actorContext(senderID: "me")
        engine.report(sender: actor.senderID)
        conversations[idx].messages.append(
            ChatMessage(text: "Reported. Thanks — this helps us spot patterns.",
                        isOutgoing: false, timestamp: Date(), isSystemNotice: true)
        )
        persist()
    }

    /// The recipient blocked this conversation's sender.
    func blockSender(in conversationID: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let actor = conversations[idx].actorContext(senderID: "me")
        engine.block(sender: actor.senderID)
        conversations[idx].messages.append(
            ChatMessage(text: "Blocked. You will not receive further messages here.",
                        isOutgoing: false, timestamp: Date(), isSystemNotice: true)
        )
        persist()
    }

    /// Behavioural risk for a conversation's sender, for the ops view.
    func behaviouralRisk(in conversationID: UUID) -> ActorRisk? {
        guard let convo = conversations.first(where: { $0.id == conversationID }) else { return nil }
        let actor = convo.actorContext(senderID: "me")
        return engine.behaviouralRisk(sender: actor.senderID, conversation: actor.conversationID)
    }

    func resolve(_ item: QueueItem, as resolution: QueueItem.Resolution) {
        guard let idx = queue.firstIndex(where: { $0.id == item.id }) else { return }
        queue[idx].resolution = resolution
        trainingExamplesCollected += 1
    }

    func runSuite() {
        isRunningSuite = true
        DispatchQueue.main.async { [weak self] in
            let report = AdversarialSuite.run()
            self?.suiteReport = report
            self?.isRunningSuite = false
        }
    }

    func runRedTeam() {
        isRunningRedTeam = true
        DispatchQueue.main.async { [weak self] in
            let report = RedTeamSuite.run()
            self?.redTeamReport = report
            self?.isRunningRedTeam = false
        }
    }

    func runComparison() {
        DispatchQueue.main.async { [weak self] in
            self?.comparison = BaselineComparison.runLocal()
        }
    }

    func measureLLMBaseline() {
        guard SecretsStore.hasAnyProvider else { return }
        llmProgress = "Starting…"
        Task { @MainActor in
            let outcome = await BaselineComparison.measureLLM(
                sampleSize: 24,
                progress: { [weak self] done, total in
                    Task { @MainActor in
                        self?.llmProgress = "Calling \(SecretsStore.providerDescription) — \(done)/\(total)"
                    }
                }
            )
            llmOutcome = outcome
            llmProgress = nil
        }
    }

    private static func notice(for verdict: Verdict) -> String? {
        switch verdict.action {
        case .allow, .hint:
            return nil
        case .mask:
            return "Part of this message was removed."
        case .warn:
            return "Your message wasn't sent."
        case .block:
            return "Your message wasn't sent."
        case .review:
            return "Your message wasn't sent."
        }
    }

    private static func seed() -> [Conversation] {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let engine = ModerationEngine.shared

        func moderated(_ text: String, outgoing: Bool, _ minutes: Double, trust: TrustTier = .standard, stage: BookingStage = .inquiry) -> ChatMessage {
            let actor = ActorContext(trust: trust, stage: stage, conversationID: "seed", senderID: outgoing ? "me" : "them")
            let v = engine.evaluate(text, actor: actor, useConversationBuffer: false)
            let status: DeliveryStatus
            switch v.action {
            case .warn, .block: status = .withheld
            case .review:       status = .underReview
            default:            status = outgoing ? .read : .delivered
            }
            return ChatMessage(text: text, isOutgoing: outgoing, timestamp: ago(minutes), verdict: v, status: status)
        }

        func plain(_ text: String, outgoing: Bool, _ minutes: Double) -> ChatMessage {
            ChatMessage(text: text, isOutgoing: outgoing, timestamp: ago(minutes), verdict: nil, status: outgoing ? .read : .delivered)
        }

        let aarav = Conversation(
            name: "Aarav Menon",
            propertyName: "Villa Serena, Assagao",
            bookingRef: "WZ-4471",
            initials: "AM",
            isHost: true,
            messages: [
                plain("Hi! Thanks for the enquiry 🙏 The villa is free for those dates.", outgoing: false, 240),
                plain("Amazing. Is early check-in possible? Our train arrives 6 am", outgoing: true, 236),
                moderated("Sure. The villa is 2400 sqft, 3 bhk, and it's 2.5 km from Anjuna beach. Total is ₹12,500 for 3 nights and 4 guests.", outgoing: false, 232),
                plain("Perfect, that works for us.", outgoing: true, 228),
                moderated("Great — easier if you just whatsapp me on nine eight seven six five four three two one zero", outgoing: false, 96),
                plain("Sorry, it wouldn't let that through. Everything alright?", outgoing: true, 92),
                moderated("no worries, my іnstа is аkshаy_villа_goа if you prefer", outgoing: false, 88),
                plain("Let's just keep it here, easier for me to track everything 🙂", outgoing: true, 84),
                moderated("Fair enough. My flight AI 2109 lands at 14:35, checkout is at 11 — will the gate be open?", outgoing: true, 12),
                plain("Yes, someone will be at the gate. See you soon!", outgoing: false, 8),
            ],
            trust: .standard,
            stage: .inquiry,
            unread: 0,
            isOnline: true
        )

        let priya = Conversation(
            name: "Priya Nair",
            propertyName: "Sea Breeze Cottage, Palolem",
            bookingRef: "WZ-4390",
            initials: "PN",
            isHost: false,
            messages: [
                plain("Is the cottage pet friendly? We have a small dog.", outgoing: false, 700),
                plain("Yes, small pets are welcome at no extra charge.", outgoing: true, 690),
                moderated("if you don't refund me I will leave a 1 star review", outgoing: false, 45),
            ],
            trust: .fresh,
            stage: .inquiry,
            priorViolations: 1,
            unread: 2
        )

        let rohan = Conversation(
            name: "Rohan Kapoor",
            propertyName: "Hilltop Studio, Vagator",
            bookingRef: "WZ-4502",
            initials: "RK",
            isHost: true,
            messages: [
                plain("Checked in fine, thanks! The place is lovely.", outgoing: true, 1500),
                plain("So glad to hear it. Let me know if you need anything.", outgoing: false, 1490),
                moderated("lets do this off platform next time, its cheaper direct and no commission", outgoing: false, 1200),
            ],
            trust: .trusted,
            stage: .checkedIn,
            unread: 1
        )

        let meera = Conversation(
            name: "Meera Fernandes",
            propertyName: "Casa Azul, Siolim",
            bookingRef: "WZ-4288",
            initials: "MF",
            isHost: false,
            messages: [
                plain("Rated 4.8 out of 5 across 126 reviews — congrats!", outgoing: false, 2900),
                plain("Thank you! We work hard on it 😊", outgoing: true, 2880),
            ],
            trust: .trusted,
            stage: .booked
        )

        let dev = Conversation(
            name: "Dev Sharma",
            propertyName: "Riverside Nest, Aldona",
            bookingRef: "WZ-4610",
            initials: "DS",
            isHost: false,
            messages: [
                moderated("send the payment to akshay@ybl please, faster than the app", outgoing: false, 4300),
            ],
            trust: .fresh,
            stage: .inquiry,
            priorViolations: 2,
            unread: 3
        )

        let ananya = Conversation(
            name: "Ananya Iyer",
            propertyName: "Palm Court, Candolim",
            bookingRef: "WZ-4155",
            initials: "AI",
            isHost: true,
            messages: [
                plain("Parking fits 2 cars, gate code will be shared after booking", outgoing: false, 5900),
            ],
            trust: .standard,
            stage: .booked
        )

        return [aarav, priya, rohan, dev, meera, ananya]
    }
}

extension Date {
    var wzTimeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: self)
    }

    var wzListLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) {
            let mins = Int(Date().timeIntervalSince(self) / 60)
            if mins < 1 { return "Just now" }
            if mins < 60 { return "\(mins)m ago" }
            return wzTimeLabel
        }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: self)
    }
}
