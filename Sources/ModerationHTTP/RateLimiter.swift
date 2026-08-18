// Per-client token bucket.
//
// A moderation endpoint is an attractive thing to hammer. Two distinct reasons to limit it, and
// they want different treatment:
//
//   * Cost. A caller that escalates heavily spends real money at Tier 3. That is bounded by the
//     routing logic rather than here.
//   * Capacity. A caller in a retry storm can occupy every worker and deny service to everyone
//     else, including the traffic that carries actual abuse. That is what this bounds.
//
// A token bucket rather than a fixed window because the failure mode of a fixed window is a
// stampede at the boundary: every client that got limited retries the instant the window rolls,
// producing exactly the synchronised spike the limit was meant to prevent. A bucket refills
// continuously, so recovery is spread out.
//
// Keyed by caller identity where there is one and by peer address otherwise. Identity is the
// better key: addresses are shared behind NAT, so limiting purely by address would let one noisy
// tenant throttle everyone behind the same egress.

import Foundation

final class RateLimiter {

    struct Decision {
        let allowed: Bool
        let remaining: Int
        let retryAfter: Int
    }

    private struct Bucket {
        var tokens: Double
        var lastRefill: Date
    }

    private let capacity: Double
    private let refillPerSecond: Double
    private let maxKeys: Int

    private let lock = NSLock()
    private var buckets: [String: Bucket] = [:]

    /// - Parameters:
    ///   - burst: how many requests a client may make back to back.
    ///   - perSecond: sustained rate once the burst is spent.
    init(burst: Int, perSecond: Double, maxKeys: Int = 100_000) {
        self.capacity = Double(max(1, burst))
        self.refillPerSecond = max(0.001, perSecond)
        self.maxKeys = maxKeys
    }

    func admit(_ key: String, at now: Date = Date()) -> Decision {
        lock.lock()
        defer { lock.unlock() }

        // Bound the key space. Without this, a caller cycling identifiers turns the limiter
        // itself into the memory leak that takes the process down.
        if buckets[key] == nil, buckets.count >= maxKeys { evictLocked(now: now) }

        var bucket = buckets[key] ?? Bucket(tokens: capacity, lastRefill: now)
        let elapsed = max(0, now.timeIntervalSince(bucket.lastRefill))
        bucket.tokens = min(capacity, bucket.tokens + elapsed * refillPerSecond)
        bucket.lastRefill = now

        let decision: Decision
        if bucket.tokens >= 1 {
            bucket.tokens -= 1
            decision = Decision(allowed: true, remaining: Int(bucket.tokens), retryAfter: 0)
        } else {
            let wait = (1 - bucket.tokens) / refillPerSecond
            decision = Decision(allowed: false, remaining: 0,
                                retryAfter: max(1, Int(wait.rounded(.up))))
        }
        buckets[key] = bucket
        return decision
    }

    private func evictLocked(now: Date) {
        // Anything already back to full has no state worth keeping.
        buckets = buckets.filter { _, bucket in
            let elapsed = now.timeIntervalSince(bucket.lastRefill)
            return min(capacity, bucket.tokens + elapsed * refillPerSecond) < capacity
        }
        guard buckets.count >= maxKeys else { return }
        for key in buckets.keys.prefix(buckets.count / 4) { buckets.removeValue(forKey: key) }
    }

    var trackedKeys: Int {
        lock.lock()
        defer { lock.unlock() }
        return buckets.count
    }
}
