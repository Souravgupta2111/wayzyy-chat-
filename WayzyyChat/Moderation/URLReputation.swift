
import Foundation

public enum HostReputation: String, Codable, CaseIterable {
    case unknown
    case suspicious
    case malicious
}

public protocol URLReputationProvider: AnyObject {
    func reputation(forHost host: String) -> HostReputation
}

public final class NeutralURLReputationProvider: URLReputationProvider {
    public init() {}
    public func reputation(forHost host: String) -> HostReputation { .unknown }
}

public final class StaticURLReputationProvider: URLReputationProvider {
    private let malicious: Set<String>
    private let suspicious: Set<String>

    public init(malicious: Set<String> = [], suspicious: Set<String> = []) {
        self.malicious = Set(malicious.map { $0.lowercased() })
        self.suspicious = Set(suspicious.map { $0.lowercased() })
    }

    public func reputation(forHost host: String) -> HostReputation {
        let h = host.lowercased()
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

    public static var provider: URLReputationProvider {
        get { lock.lock(); defer { lock.unlock() }; return _provider }
        set { lock.lock(); _provider = newValue; lock.unlock() }
    }

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

    public static var allowlistCount: Int { allowlistedHosts.count }
}
