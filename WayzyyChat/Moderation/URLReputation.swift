// A seam for host reputation, and the operator-controlled allowlist.
//
// The URL detector recognises *shapes*: shorteners, punycode, a TLD allowlist. Shape is a proxy
// for intent and it has a fixed ceiling — a host that looks ordinary is scored as an ordinary
// external link no matter what is actually hosted there, and a host on a TLD outside the
// allowlist is not detected at all. Reputation is the signal that closes that gap, and it has
// to come from outside the process because it changes hourly.
//
// One rule governs the whole seam: reputation may raise suspicion, never lower it.
//
// This is not defensive coding, it follows from what the URL rules are for. They exist because
// steering a guest off-platform removes them from payment protection and dispute resolution.
// That harm does not depend on whether the destination hosts malware, so a reputation provider
// answering "this host is clean" says nothing about whether sharing it is acceptable. If
// "clean" could de-escalate, then every contact-exfiltration rule would be one third-party API
// response away from being switched off — and an attacker choosing a reputable-looking host
// would be rewarded for it.
//
// De-escalation therefore stays with the operator, in `allowlistedHosts`, which is loaded from
// configuration this deployment controls rather than from a vendor's opinion.

import Foundation

public enum HostReputation: String, Codable, CaseIterable {
    /// No information. The default, and the only answer a provider is required to give.
    case unknown
    /// Elevated concern: newly registered, bulk-registered, mixed abuse history.
    case suspicious
    /// Known-bad: phishing, malware, fraud.
    case malicious
}

public protocol URLReputationProvider: AnyObject {
    /// Must not block. Called on the synchronous write path, so an implementation backed by a
    /// network service is required to answer from a local cache and refresh out of band —
    /// exactly as the safety classifier does.
    func reputation(forHost host: String) -> HostReputation
}

/// The default. Knows nothing, so shape-based detection decides on its own and behaviour is
/// identical to having no provider at all.
public final class NeutralURLReputationProvider: URLReputationProvider {
    public init() {}
    public func reputation(forHost host: String) -> HostReputation { .unknown }
}

/// Fixed lists, for deployments that ship a feed snapshot rather than call a service.
public final class StaticURLReputationProvider: URLReputationProvider {
    private let malicious: Set<String>
    private let suspicious: Set<String>

    public init(malicious: Set<String> = [], suspicious: Set<String> = []) {
        self.malicious = Set(malicious.map { $0.lowercased() })
        self.suspicious = Set(suspicious.map { $0.lowercased() })
    }

    public func reputation(forHost host: String) -> HostReputation {
        let h = host.lowercased()
        // Registrable-suffix walk, so a feed entry for `bad.example` also covers
        // `login.bad.example`. Subdomains are free to create, so listing only the exact host
        // would make the feed trivial to sidestep.
        var parts = h.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            let candidate = parts.joined(separator: ".")
            if malicious.contains(candidate) { return .malicious }
            if suspicious.contains(candidate) { return .suspicious }
            parts.removeFirst()
        }
        return .unknown
    }
}

public enum URLReputation {

    private static let lock = NSLock()
    private static var _provider: URLReputationProvider = NeutralURLReputationProvider()
    private static var _allowlist: Set<String> = URLReputation.loadAllowlist()

    /// Swappable at runtime. Guarded, because a provider swap during a rollout races every
    /// in-flight evaluation.
    public static var provider: URLReputationProvider {
        get { lock.lock(); defer { lock.unlock() }; return _provider }
        set { lock.lock(); _provider = newValue; lock.unlock() }
    }

    /// Hosts this deployment treats as its own. The only de-escalation path, and deliberately
    /// operator-owned rather than provider-owned.
    public static var allowlistedHosts: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return _allowlist }
        set { lock.lock(); _allowlist = Set(newValue.map { $0.lowercased() }); lock.unlock() }
    }

    static func isAllowlisted(host: String) -> Bool {
        let h = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if _allowlist.contains(h) { return true }
        var parts = h.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            if _allowlist.contains(parts.joined(separator: ".")) { return true }
            parts.removeFirst()
        }
        return false
    }

    /// Apply reputation to a shape-derived confidence.
    ///
    /// `shapeConfidence` is nil when the shape rules found nothing. Reputation can still
    /// produce a detection in that case — that is the gap it exists to close — but only for a
    /// host that is actually known bad, never on an absence of information.
    static func adjust(host: String,
                       shapeConfidence: Double?,
                       shapeReason: String?) -> (Double, String)? {
        let verdict = provider.reputation(forHost: host)
        switch verdict {
        case .malicious:
            return (Swift.max(shapeConfidence ?? 0, 0.95),
                    (shapeReason ?? "External link") + " — host reported malicious")
        case .suspicious:
            return (Swift.max(shapeConfidence ?? 0, 0.85),
                    (shapeReason ?? "External link") + " — host reported suspicious")
        case .unknown:
            // Never lowers, never invents. If the shape said nothing, nothing is reported.
            guard let shapeConfidence, let shapeReason else { return nil }
            return (shapeConfidence, shapeReason)
        }
    }

    private static func loadAllowlist() -> Set<String> {
        var hosts: Set<String> = ["wayzyy.com", "wayzyy.in", "wayzyy"]
        if let raw = ProcessInfo.processInfo.environment["WAYZYY_URL_ALLOWLIST"] {
            for host in raw.split(whereSeparator: { ",; \n\t".contains($0) }) {
                hosts.insert(host.lowercased())
            }
        }
        return hosts
    }

    /// Exposed so a deployment can assert its configuration actually loaded.
    public static var allowlistCount: Int { allowlistedHosts.count }
}
