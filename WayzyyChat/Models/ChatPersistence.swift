// JSON persistence for conversations; stores original text only and re-derives verdicts on load.

import Foundation

enum ChatPersistence {

    private struct MessageDTO: Codable {
        var text: String
        var isOutgoing: Bool
        var timestamp: Date
        var isSystemNotice: Bool
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

    private static let currentVersion = 3

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
                            isSystemNotice: $0.isSystemNotice
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
              dto.version == currentVersion,
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
                let verdict = engine.evaluate(m.text, actor: actor, useConversationBuffer: false)
                let status: DeliveryStatus
                switch verdict.action {
                case .warn, .block: status = .withheld
                case .review:       status = .underReview
                default:            status = m.isOutgoing ? .read : .delivered
                }
                return ChatMessage(
                    text: m.text, isOutgoing: m.isOutgoing, timestamp: m.timestamp,
                    verdict: verdict.action == .allow ? nil : verdict, status: status
                )
            }
            return conversation
        }
    }

    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
