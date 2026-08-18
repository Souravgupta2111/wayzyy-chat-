// Wayzyy moderation — HTTP front end.
//
// The engine is reached only through the public `WayzyyModerationService` facade, so this file
// contains no moderation logic: it is transport, authentication, admission control and
// observability. Swapping to gRPC or a queue consumer means replacing this file and nothing else.
//
//   POST /v1/moderate   evaluate a message, durably
//   POST /v1/signal     record a recipient report or block
//   POST /v1/context    booking stage / trust / priors from the platform DB
//   GET  /health        liveness — is the process up
//   GET  /ready         readiness — is it configured well enough to serve
//   GET  /metrics       Prometheus text
//
// Liveness and readiness are separate on purpose. Liveness answers "should this container be
// restarted", and restarting is the wrong response to a missing adjudicator — the replacement
// would come up equally misconfigured. Readiness answers "should traffic be sent here", and that
// is the correct lever for a pod that started but cannot do its job properly.

import Foundation
import WayzyyModeration

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

let env = ProcessInfo.processInfo.environment

func intEnv(_ name: String, default fallback: Int) -> Int {
    guard let raw = env[name], let value = Int(raw) else { return fallback }
    return value
}

// MARK: - Startup

let report: BootstrapReport
do {
    report = try WayzyyModerationService.bootstrap()
} catch {
    FileHandle.standardError.write(Data("startup failed: \(error)\n".utf8))
    exit(78)   // EX_CONFIG
}

// Authentication is required unless explicitly waived. A moderation endpoint reachable without a
// credential is not merely an information leak: `POST /v1/signal` lets a caller manufacture
// reports and blocks against any sender, which is the highest-precision evidence the engine has.
// An attacker who can forge those can drive an innocent sender towards enforcement. So the
// default is to refuse to start, and running open has to be a decision someone typed.
let apiTokens: Set<String> = {
    let raw = env["WAYZYY_API_TOKEN"] ?? ""
    return Set(raw.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init))
}()

let allowAnonymous = env["WAYZYY_ALLOW_ANONYMOUS"] != nil

if apiTokens.isEmpty && !allowAnonymous {
    FileHandle.standardError.write(Data("""
        startup failed: no WAYZYY_API_TOKEN configured.
        Refusing to start. POST /v1/signal accepts reports and blocks, which raise enforcement \
        pressure on a sender, so an unauthenticated endpoint lets anyone manufacture evidence \
        against anyone. Set WAYZYY_API_TOKEN=<token>[,<token>...], or set \
        WAYZYY_ALLOW_ANONYMOUS=1 to run open deliberately.\n
        """.utf8))
    exit(78)
}

let port = UInt16(intEnv("WAYZYY_PORT", default: 8_080))
let limiter = RateLimiter(
    burst: intEnv("WAYZYY_RATE_BURST", default: 200),
    perSecond: Double(intEnv("WAYZYY_RATE_PER_SECOND", default: 100))
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let decoder = JSONDecoder()

// MARK: - Helpers

/// Compare in constant time. A token check that returns early on the first wrong byte leaks the
/// token's prefix through timing, which is a slow but real way to guess it.
func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in x.indices { diff |= x[i] ^ y[i] }
    return diff == 0
}

func authenticate(_ request: HTTPRequest) -> String? {
    if allowAnonymous && apiTokens.isEmpty { return "anonymous" }
    guard let header = request.header("authorization") else { return nil }
    let presented = header.hasPrefix("Bearer ")
        ? String(header.dropFirst("Bearer ".count))
        : header
    for token in apiTokens where constantTimeEqual(token, presented) {
        // Identify the caller by a short fingerprint, never by the token itself: the rate
        // limiter key and the log line both end up somewhere a token should not.
        return "t-\(token.prefix(4))\(token.count)"
    }
    return nil
}

func queryValue(_ path: String, _ name: String) -> String? {
    guard let rawQuery = path.split(separator: "?", maxSplits: 1).dropFirst().first else {
        return nil
    }
    for pair in rawQuery.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        guard parts.count == 2, parts[0] == name[...] else { continue }
        let raw = String(parts[1]).replacingOccurrences(of: "+", with: " ")
        return raw.removingPercentEncoding ?? raw
    }
    return nil
}

func encodeJSON<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
    guard let data = try? encoder.encode(value) else {
        return .error(500, "response encoding failed")
    }
    return .json(status, data)
}

// MARK: - Routes

func route(_ request: HTTPRequest) -> HTTPResponse {
    let started = DispatchTime.now().uptimeNanoseconds
    var status = 200
    defer {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        Metrics.shared.recordRequest(status: status, latencyMs: elapsed)
    }

    // Unauthenticated endpoints. Neither reveals anything about a conversation, and a probe
    // that requires a credential is a probe that fails during exactly the incident it exists
    // to report on.
    switch (request.method, request.path) {
    case ("GET", "/health"):
        return .json(200, Data(#"{"ok":true}"#.utf8))

    case ("GET", "/ready"):
        // Unauthenticated probes get a boolean only. The full bootstrap report names
        // adjudicator and store internals; that is behind the bearer token.
        let ready = report.lexiconsSealed && (report.tier3Available || env["WAYZYY_TIER3"] == "off")
        status = ready ? 200 : 503
        if authenticate(request) != nil {
            return encodeJSON(report, status: status)
        }
        let body = ready ? #"{"ok":true}"# : #"{"ok":false}"#
        return .json(status, Data(body.utf8))

    default:
        break
    }

    guard let caller = authenticate(request) else {
        Metrics.shared.recordUnauthorised()
        status = 401
        return .error(401, "missing or invalid bearer token")
    }

    // Prefer identity over address: addresses are shared behind NAT, so limiting by address
    // alone would let one noisy tenant throttle everyone sharing its egress.
    let limit = limiter.admit(caller == "anonymous" ? request.peer : caller)
    guard limit.allowed else {
        Metrics.shared.recordRateLimited()
        status = 429
        var response = HTTPResponse.error(429, "rate limit exceeded")
        response.extraHeaders["Retry-After"] = "\(limit.retryAfter)"
        return response
    }

    if request.body == Data("__oversized__".utf8) {
        Metrics.shared.recordTooLarge()
        status = 413
        return .error(413, "request exceeds \(ModerationLimits.maxRequestBytes) bytes")
    }

    switch (request.method, request.path) {
    case ("GET", "/metrics"):
        return .text(200, Metrics.shared.scrape(), contentType: "text/plain; version=0.0.4")

    case ("POST", "/v1/moderate"):
        guard let dto = try? decoder.decode(ModerationRequestDTO.self, from: request.body) else {
            status = 400
            return .error(400, "malformed JSON request")
        }
        do {
            let verdict = try WayzyyModerationService.handleDurably(dto)
            Metrics.shared.recordVerdict(verdict)
            Log.emit([
                "event": "moderate",
                "caller": caller,
                "request_id": verdict.id ?? "",
                "action": verdict.action ?? "",
                "tier": verdict.tierReached ?? 0,
                "escalated": verdict.escalationCandidate ?? false,
                "replay": verdict.idempotentReplay ?? false,
                "reasons": verdict.reasonCodes ?? [],
                "latency_ms": verdict.latencyMs ?? 0,
            ])
            status = verdict.ok ? 200 : 400
            return encodeJSON(verdict, status: status)
        } catch {
            // A decision the store never saw cannot be appealed or reconciled, so it must not
            // be returned as though it had been recorded.
            Metrics.shared.recordStoreFailure()
            Log.emit(["event": "store_failure", "caller": caller, "error": "\(error)"])
            status = 503
            return .error(503, "decision could not be recorded")
        }

    case ("GET", let path) where path.hasPrefix("/v1/decision"):
        guard let id = queryValue(path, "id"), !id.isEmpty else {
            status = 400
            return .error(400, "missing id query parameter")
        }
        let state = WayzyyModerationService.status(forRequestID: id)
        status = state.found ? 200 : 404
        return encodeJSON(state, status: status)

    case ("POST", "/v1/signal"):
        guard let dto = try? decoder.decode(RecipientSignalDTO.self, from: request.body) else {
            status = 400
            return .error(400, "malformed JSON request")
        }
        let ack = WayzyyModerationService.handle(dto)
        Log.emit([
            "event": "signal",
            "caller": caller,
            "op": dto.op,
            "sender": dto.senderID,
            "ok": ack.ok,
        ])
        status = ack.ok ? 200 : 400
        return encodeJSON(ack, status: status)

    case ("POST", "/v1/context"):
        guard let dto = try? decoder.decode(ConversationContextDTO.self, from: request.body) else {
            status = 400
            return .error(400, "malformed JSON request")
        }
        let ack = WayzyyModerationService.handle(dto)
        Log.emit([
            "event": "context",
            "caller": caller,
            "conversation": dto.conversationID,
            "ok": ack.ok,
        ])
        status = ack.ok ? 200 : 400
        return encodeJSON(ack, status: status)

    case ("GET", _), ("POST", _):
        status = 404
        return .error(404, "no such route")

    default:
        status = 405
        return .error(405, "method not allowed")
    }
}

// MARK: - Run

let bindHost = env["WAYZYY_BIND"] ?? "0.0.0.0"

let server = HTTPServer(
    port: port,
    bindHost: bindHost,
    maxConcurrent: intEnv("WAYZYY_MAX_CONCURRENT", default: 64),
    handler: route
)

do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("listen failed: \(error)\n".utf8))
    exit(75)   // EX_TEMPFAIL — the port is unavailable, which may be transient
}

// Adjudication continues after a response is sent, so a rolling update that exits the instant
// SIGTERM arrives abandons judgements on exactly the messages the deterministic tiers were least
// certain about. Drain them, bounded, then leave. The orchestrator's grace period has to exceed
// this window, which is why the manifest pairs it with a preStop delay.
let shutdown = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
shutdown.setEventHandler {
    let drained = WayzyyModerationService.drainAdjudications(timeout: 20)
    let stats = WayzyyModerationService.adjudicationStats
    Log.emit(["event": "shutdown", "drained": drained,
              "adjudications": stats.completed, "changed": stats.changed,
              "dropped": stats.dropped])
    exit(0)
}
shutdown.resume()
signal(SIGTERM, SIG_IGN)   // handled by the dispatch source above

if let data = try? encoder.encode(report), let line = String(data: data, encoding: .utf8) {
    Log.emit(["event": "startup", "port": Int(port), "bind": bindHost, "report": line,
              "auth": apiTokens.isEmpty ? "anonymous" : "bearer",
              "tokens": apiTokens.count,
              "tls": "ingress-only — do not point Expo at this port"])
}

server.serve()
