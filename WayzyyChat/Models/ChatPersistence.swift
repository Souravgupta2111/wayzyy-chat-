// JSON persistence for conversations. Stores the decision that was actually made, not just the
// text — see DecisionRecord for why re-deriving a verdict on load is not the same thing as
// remembering it. Version 3 snapshots predate durable decisions and are still readable; their
// verdicts are re-derived once on load and marked as such, then stored properly on next save.

import Foundation

enum ChatPersistence {

    private struct MessageDTO: Codable {
        var text: String
        var isOutgoing: Bool
        var timestamp: Date
        var isSystemNotice: Bool
        /// The decision as made. Absent for clean messages and for version 3 snapshots.
        var decision: DecisionRecord?
        /// What the recipient actually saw. Persisted rather than derived, so a policy change
        /// cannot retroactively withhold a message that was delivered.
        var status: String?
        var revealed: Bool?
    }

    private struct ConversationDTO: Codable {
        var name: String
        var propertyName: String
        var bookingRef: String
        var initials: String
        var isHost: Bool
        var trust: String
        var stage: String
        var priorViolations: Int
        var unread: Int
        var isOnline: Bool
        var messages: [MessageDTO]
    }

    private struct SnapshotDTO: Codable {
        var version: Int
        var savedAt: Date
        var conversations: [ConversationDTO]
    }

    private static let currentVersion = 4
    /// Readable but upgraded on load: no per-message decisions.
    private static let legacyVersion = 3

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("wayzyy-chats.json")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func save(_ conversations: [Conversation]) {
        let dto = SnapshotDTO(
            version: currentVersion,
            savedAt: Date(),
            conversations: conversations.map { c in
                ConversationDTO(
                    name: c.name,
                    propertyName: c.propertyName,
                    bookingRef: c.bookingRef,
                    initials: c.initials,
                    isHost: c.isHost,
                    trust: c.trust.rawValue,
                    stage: c.stage.rawValue,
                    priorViolations: c.priorViolations,
                    unread: c.unread,
                    isOnline: c.isOnline,
                    messages: c.messages.map {
                        MessageDTO(
                            text: $0.text,
                            isOutgoing: $0.isOutgoing,
                            timestamp: $0.timestamp,
                            isSystemNotice: $0.isSystemNotice,
                            decision: $0.verdict?.decisionRecord,
                            status: $0.status.rawValue,
                            revealed: $0.revealed
                        )
                    }
                )
            }
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(dto)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[persistence] save failed: \(error.localizedDescription)")
        }
    }

    static func load() -> [Conversation]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let dto = try? decoder.decode(SnapshotDTO.self, from: data),
              dto.version == currentVersion || dto.version == legacyVersion,
              !dto.conversations.isEmpty
        else { return nil }

        let engine = ModerationEngine.shared

        return dto.conversations.map { c in
            let trust = TrustTier(rawValue: c.trust) ?? .standard
            let stage = BookingStage(rawValue: c.stage) ?? .inquiry

            var conversation = Conversation(
                name: c.name,
                propertyName: c.propertyName,
                bookingRef: c.bookingRef,
                initials: c.initials,
                isHost: c.isHost,
                messages: [],
                trust: trust,
                stage: stage,
                priorViolations: c.priorViolations,
                unread: c.unread,
                isOnline: c.isOnline
            )

            let actor = ActorContext(
                trust: trust, stage: stage, priorViolations: c.priorViolations,
                conversationID: conversation.id.uuidString, senderID: "restore"
            )
            engine.resetBuffer(actor: actor)

            conversation.messages = c.messages.map { m in
                if m.isSystemNotice {
                    return ChatMessage(
                        text: m.text, isOutgoing: false, timestamp: m.timestamp,
                        verdict: nil, status: .delivered, isSystemNotice: true
                    )
                }

                let verdict: Verdict?
                if let record = m.decision {
                    // The decision as it was made. No engine call, no policy read: restoring a
                    // fact must not become an opportunity to change it.
                    verdict = Verdict(restoring: record)
                } else if m.status != nil {
                    // Version 4 with no decision means the message was clean at the time.
                    verdict = nil
                } else {
                    // Version 3 only. Re-derive once, flagged, so it is never mistaken for
                    // evidence of the original decision. Saved properly on next save.
                    var derived = engine
                        .evaluate(m.text, actor: actor, useConversationBuffer: false)
                    guard derived.action != .allow else { return ChatMessage(
                        text: m.text, isOutgoing: m.isOutgoing, timestamp: m.timestamp,
                        verdict: nil, status: m.isOutgoing ? .read : .delivered
                    ) }
                    derived.reasonCodes.append("DECISION_RE_DERIVED")
                    verdict = derived
                }

                let status = m.status.flatMap(DeliveryStatus.init(rawValue:))
                    ?? Self.status(for: verdict?.action, isOutgoing: m.isOutgoing)

                var message = ChatMessage(
                    text: m.text, isOutgoing: m.isOutgoing, timestamp: m.timestamp,
                    verdict: verdict, status: status
                )
                message.revealed = m.revealed ?? false
                return message
            }
            return conversation
        }
    }

    /// Only for records that never had a stored status — a version 3 snapshot.
    private static func status(for action: ModAction?, isOutgoing: Bool) -> DeliveryStatus {
        switch action {
        case .warn, .block: return .withheld
        case .review:       return .underReview
        default:            return isOutgoing ? .read : .delivered
        }
    }

    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
