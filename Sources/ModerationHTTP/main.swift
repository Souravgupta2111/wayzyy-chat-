
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


let report: BootstrapReport
do {
    report = try WayzyyModerationService.bootstrap()
} catch {
    FileHandle.standardError.write(Data("startup failed: \(error)\n".utf8))
    exit(78)   // EX_CONFIG
}

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


func route(_ request: HTTPRequest) -> HTTPResponse {
    let started = DispatchTime.now().uptimeNanoseconds
    var status = 200
    defer {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        Metrics.shared.recordRequest(status: status, latencyMs: elapsed)
    }

    switch (request.method, request.path) {
    case ("GET", "/health"):
        return .json(200, Data(#"{"ok":true}"#.utf8))

    case ("GET", "/ready"):
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

    if request.method == "POST" {
        let limit = limiter.admit(caller == "anonymous" ? request.peer : caller)
        guard limit.allowed else {
            Metrics.shared.recordRateLimited()
            status = 429
            var response = HTTPResponse.error(429, "rate limit exceeded")
            response.extraHeaders["Retry-After"] = "\(limit.retryAfter)"
            return response
        }
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
