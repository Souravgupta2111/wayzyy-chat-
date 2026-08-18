// Counters, and the structured log line.
//
// What to measure is a design decision, not a formality. A moderation service can be perfectly
// healthy by infrastructure standards — low latency, no errors, no restarts — while doing the
// wrong thing to every message. So the counters here are chosen so that the two failure modes
// that actually matter are visible:
//
//   * Enforcement drift. `action_total` broken down by action is the only way to notice that a
//     deploy started withholding twice as much as yesterday. A rise in `mask` is a product
//     incident even though nothing is technically wrong.
//   * Holds that nobody drains. `action_total{action="review"}` climbing while
//     `tier3_available` is 0 is the specific condition that silently converts real traffic into
//     messages no one will ever read.
//
// Escalation rate is also here because it is the cost driver: at roughly 1,650× the cost of a
// deterministic decision, a change in routing is a change in the bill.
//
// Format is Prometheus text, because it is scrapeable by everything and needs no client library
// — consistent with the package having no dependencies.

import Foundation
import WayzyyModeration

final class Metrics {

    static let shared = Metrics()

    private let lock = NSLock()

    private var requests = 0
    private var byAction: [String: Int] = [:]
    private var byStatus: [Int: Int] = [:]
    private var escalationCandidates = 0
    private var rejectedUnauthorised = 0
    private var rejectedRateLimited = 0
    private var rejectedTooLarge = 0
    private var idempotentReplays = 0
    private var storeFailures = 0
    private var latencies: [Double] = []
    private let startedAt = Date()

    private let maxLatencySamples = 4_096

    func recordRequest(status: Int, latencyMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        byStatus[status, default: 0] += 1
        // Reservoir-free but bounded: keep the most recent window rather than growing forever.
        latencies.append(latencyMs)
        if latencies.count > maxLatencySamples { latencies.removeFirst(latencies.count - maxLatencySamples) }
    }

    func recordVerdict(_ verdict: ModerationVerdictDTO) {
        lock.lock()
        defer { lock.unlock() }
        if let action = verdict.action { byAction[action, default: 0] += 1 }
        if verdict.escalationCandidate == true { escalationCandidates += 1 }
        if verdict.idempotentReplay == true { idempotentReplays += 1 }
    }

    func recordUnauthorised() { lock.lock(); rejectedUnauthorised += 1; lock.unlock() }
    func recordRateLimited() { lock.lock(); rejectedRateLimited += 1; lock.unlock() }
    func recordTooLarge() { lock.lock(); rejectedTooLarge += 1; lock.unlock() }
    func recordStoreFailure() { lock.lock(); storeFailures += 1; lock.unlock() }

    private func percentileLocked(_ p: Double) -> Double {
        guard !latencies.isEmpty else { return 0 }
        let sorted = latencies.sorted()
        let index = min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.down))))
        return sorted[index]
    }

    /// Prometheus text exposition.
    func scrape() -> String {
        lock.lock()
        defer { lock.unlock() }

        var out = ""
        func gauge(_ name: String, _ help: String, _ value: String) {
            out += "# HELP \(name) \(help)\n# TYPE \(name) gauge\n\(name) \(value)\n"
        }
        func counter(_ name: String, _ help: String, _ value: Int) {
            out += "# HELP \(name) \(help)\n# TYPE \(name) counter\n\(name) \(value)\n"
        }

        counter("wayzyy_requests_total", "Moderation requests served.", requests)

        out += "# HELP wayzyy_action_total Verdicts by action.\n# TYPE wayzyy_action_total counter\n"
        for action in ["allow", "hint", "mask", "warn", "review", "block"] {
            out += "wayzyy_action_total{action=\"\(action)\"} \(byAction[action] ?? 0)\n"
        }

        out += "# HELP wayzyy_responses_total Responses by HTTP status.\n"
        out += "# TYPE wayzyy_responses_total counter\n"
        for (status, count) in byStatus.sorted(by: { $0.key < $1.key }) {
            out += "wayzyy_responses_total{status=\"\(status)\"} \(count)\n"
        }

        counter("wayzyy_escalation_candidates_total",
                "Messages routed to Tier 3. The cost driver.", escalationCandidates)
        counter("wayzyy_idempotent_replays_total",
                "Requests served from the decision store rather than re-evaluated.", idempotentReplays)
        counter("wayzyy_rejected_unauthorised_total", "Requests rejected for auth.", rejectedUnauthorised)
        counter("wayzyy_rejected_rate_limited_total", "Requests rejected by the limiter.", rejectedRateLimited)
        counter("wayzyy_rejected_too_large_total", "Requests exceeding the size caps.", rejectedTooLarge)
        counter("wayzyy_decision_store_failures_total",
                "Decisions that could not be recorded. Any value above zero means unappealable enforcement.",
                storeFailures)

        // HELP/TYPE only: the samples that follow are all labelled, and emitting a bare
        // `wayzyy_latency_ms` line with no value is a parse error for a Prometheus scraper.
        out += "# HELP wayzyy_latency_ms Request latency percentiles.\n"
        out += "# TYPE wayzyy_latency_ms gauge\n"
        out += "wayzyy_latency_ms{quantile=\"0.5\"} \(String(format: "%.3f", percentileLocked(0.5)))\n"
        out += "wayzyy_latency_ms{quantile=\"0.95\"} \(String(format: "%.3f", percentileLocked(0.95)))\n"
        out += "wayzyy_latency_ms{quantile=\"0.99\"} \(String(format: "%.3f", percentileLocked(0.99)))\n"

        // The pairing that matters: holds accumulating with no adjudicator to resolve them.
        gauge("wayzyy_tier3_available",
              "1 when a real adjudicator is reachable. Review holds are undrainable at 0.",
              WayzyyModerationService.tier3Available ? "1" : "0")
        gauge("wayzyy_committed_decisions",
              "Decisions in the active store.", "\(WayzyyModerationService.committedDecisionCount)")
        gauge("wayzyy_uptime_seconds", "Process uptime.",
              String(format: "%.0f", Date().timeIntervalSince(startedAt)))

        // Tier 3 is where novel abuse is caught, and it runs after the message was answered.
        // `changed` is the number that matters: judgements that altered the outcome are the
        // ones the platform had to act on, and a `changed` rate near zero means either the
        // routing is too loose or the adjudicator is not earning its cost.
        let adjudication = WayzyyModerationService.adjudicationStats
        gauge("wayzyy_adjudications_in_flight", "Judgements running now.", "\(adjudication.inFlight)")
        counter("wayzyy_adjudications_total", "Judgements completed.", adjudication.completed)
        counter("wayzyy_adjudications_changed_total",
                "Judgements that changed the action after delivery.", adjudication.changed)
        counter("wayzyy_adjudications_dropped_total",
                "Judgements skipped because the concurrency ceiling was reached.",
                adjudication.dropped)

        return out
    }
}

/// One JSON object per line on stdout.
///
/// Deliberately never includes message text. A moderation log is a magnet for exactly the
/// content the product promises to handle carefully, and a log aggregator is a much wider
/// audience than the conversation was. Identifiers, the action and the reason codes are enough
/// to debug a decision; the text itself lives in the decision store, behind whatever access
/// control that store has.
enum Log {

    private static let lock = NSLock()
    private static let encoder = JSONEncoder()

    static func emit(_ fields: [String: Any]) {
        var payload = fields
        payload["ts"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else { return }
        lock.lock()
        print(line)
        fflush(stdout)
        lock.unlock()
    }
}
