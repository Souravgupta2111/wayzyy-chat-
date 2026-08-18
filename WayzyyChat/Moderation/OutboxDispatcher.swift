// Pushes outbox events to the chat platform so an async judgement can retract a message
// without the client polling.
//
// Never called on the send path. `kick()` enqueues a flush on a utility queue; a timer
// retries if the webhook was down.

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class OutboxDispatcher {

    public static let shared = OutboxDispatcher()

    private let lock = NSLock()
    private var webhookURL: URL?
    private var token: String?
    private var timer: DispatchSourceTimer?
    private let session: URLSession
    private let work = DispatchQueue(label: "wayzyy.outbox", qos: .utility)

    private init() {
        let sc = URLSessionConfiguration.default
        sc.timeoutIntervalForRequest = 5
        session = URLSession(configuration: sc)
    }

    public func configure(url: String, token: String?) {
        lock.lock()
        webhookURL = URL(string: url)
        self.token = token
        lock.unlock()
        startTimer()
        kick()
    }

    /// Non-blocking. Safe to call from `/v1/moderate`.
    public func kick() {
        work.async { [weak self] in self?.flush() }
    }

    public func flush() {
        lock.lock()
        let configured = webhookURL != nil
        lock.unlock()
        guard configured else { return }
        let store = WayzyyModerationService.decisionStore
        let pending = store.pendingEvents(limit: 50)
        guard !pending.isEmpty else { return }

        var delivered: [String] = []
        for event in pending {
            if post(event) { delivered.append(event.id) }
            else { break }
        }
        if !delivered.isEmpty {
            try? store.markDelivered(delivered)
        }
    }

    private func startTimer() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t
    }

    private func post(_ event: OutboxEvent) -> Bool {
        lock.lock()
        let url = webhookURL
        let token = self.token
        lock.unlock()
        guard let url else { return false }

        let status = WayzyyModerationService.status(forRequestID: event.requestID)
        var body: [String: Any] = [
            "id": event.id,
            "request_id": event.requestID,
            "kind": event.kind.rawValue,
            "subject": event.subject,
            "occurred_at": ISO8601DateFormatter().string(from: event.occurredAt),
        ]
        // `display` is the only object that may be written into chat.
        // `audit` is for the platform backend; do not send it to either participant.
        if let display = status.display {
            body["display"] = [
                "action": display.action as Any,
                "text": display.text as Any,
            ]
        }
        if event.kind == .adjudication || event.kind == .decision {
            body["audit"] = [
                "action": status.audit?.action as Any,
                "categories": status.audit?.categories as Any,
                "reasonCodes": status.audit?.reasonCodes as Any,
                "policyVersion": status.audit?.policyVersion as Any,
                "score": status.audit?.score as Any,
                "superseded": status.superseded,
            ]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var ok = false
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { _, response, error in
            if error == nil, let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                ok = true
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 6)
        return ok
    }
}
