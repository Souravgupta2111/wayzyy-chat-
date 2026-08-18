// A small HTTP/1.1 server on POSIX sockets.
//
// Why not a web framework
// ───────────────────────
// `Package.swift` has no external dependencies, and that is load-bearing rather than
// decorative: it is why the invariant gate runs with no network, no package resolution and no
// full Xcode toolchain, on any machine. Adding Hummingbird or Vapor to expose four routes would
// trade that away for request routing this file can do in a few hundred lines.
//
// The scope is deliberately narrow, because a general-purpose HTTP server is a large security
// surface and this needs almost none of it. Supported: HTTP/1.1, fixed `Content-Length` bodies,
// one request per connection. Not supported, and rejected rather than half-handled: chunked
// transfer encoding, pipelining, keep-alive, upgrades, TLS. TLS terminates at the ingress, which
// is where it belongs — a service that also terminates TLS has to be redeployed to rotate a
// certificate.
//
// Hardening choices worth naming:
//
//   * A read timeout on every socket. Without one, a client that opens a connection and sends
//     nothing occupies a worker forever, which is a denial of service that costs the attacker
//     one socket and needs no traffic at all.
//   * A bounded worker pool with a bounded accept queue. Unbounded concurrency converts a
//     traffic spike into an out-of-memory kill, which is strictly worse than refusing some
//     requests: refusing is visible and recoverable.
//   * Body size checked against `Content-Length` *before* reading the body, so an oversized
//     request is refused without allocating room for it.

import Foundation
import WayzyyModeration

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
    var peer: String

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse {
    var status: Int
    var body: Data
    var contentType: String
    var extraHeaders: [String: String] = [:]

    static func json(_ status: Int, _ body: Data) -> HTTPResponse {
        HTTPResponse(status: status, body: body, contentType: "application/json")
    }

    static func text(_ status: Int, _ body: String, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, body: Data(body.utf8), contentType: contentType)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        let escaped = message.replacingOccurrences(of: "\"", with: "'")
        return .json(status, Data(#"{"ok":false,"error":"\#(escaped)"}"#.utf8))
    }
}

final class HTTPServer {

    private let port: UInt16
    private let bindHost: String
    private let maxConcurrent: Int
    /// Accepted connections allowed to wait for a worker. Sized well above `maxConcurrent`
    /// because each request finishes in single-digit milliseconds, so a burst that waits
    /// briefly is served correctly — while an unbounded queue would just defer the failure.
    private let maxQueued: Int
    private let readTimeout: TimeInterval
    private let handler: (HTTPRequest) -> HTTPResponse

    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "wayzyy.http", attributes: .concurrent)

    init(port: UInt16,
         bindHost: String = "0.0.0.0",
         maxConcurrent: Int = 64,
         maxQueued: Int = 2_048,
         readTimeout: TimeInterval = 15,
         handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.port = port
        self.bindHost = bindHost
        self.maxConcurrent = maxConcurrent
        self.maxQueued = maxQueued
        self.readTimeout = readTimeout
        self.handler = handler
    }

    enum ServerError: Error, CustomStringConvertible {
        case socketFailed(String)

        var description: String {
            switch self {
            case .socketFailed(let detail): return "socket error: \(detail)"
            }
        }
    }

    #if canImport(Glibc)
    private let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    private let streamType = SOCK_STREAM
    #endif

    func start() throws {
        listenFD = socket(AF_INET, streamType, 0)
        guard listenFD >= 0 else { throw ServerError.socketFailed("socket() failed") }

        // Without SO_REUSEADDR a restart fails for the duration of TIME_WAIT, which turns every
        // deploy into a minute of downtime.
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if bindHost == "0.0.0.0" || bindHost == "*" {
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        } else {
            _ = bindHost.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(listenFD)
            throw ServerError.socketFailed("bind() failed on port \(port) — errno \(errno)")
        }
        // The backlog is deliberately much larger than the worker pool.
        //
        // Workers are bounded so that concurrency cannot exhaust memory, which means the accept
        // loop pauses while all workers are busy. Connections then wait in the kernel's queue —
        // and if that queue is small, the kernel *resets* the overflow instead of queueing it.
        //
        // A reset is the wrong way to shed load. The client sees a transport error rather than a
        // status code, so it cannot tell "you are overloaded, retry" from "you are broken", and
        // a moderation client that cannot tell those apart will either drop the message or spin.
        // Since each request completes in single-digit milliseconds, a burst that queues briefly
        // is served correctly; a burst that is reset is not. Measured: 500 simultaneous
        // connections were reset at a backlog of 128 and are served at 1024.
        let backlog = Int32(max(1024, maxConcurrent * 16))
        guard listen(listenFD, backlog) == 0 else {
            close(listenFD)
            throw ServerError.socketFailed("listen() failed — errno \(errno)")
        }
    }

    /// Accept forever. Blocks the calling thread.
    ///
    /// The shape here is deliberate, and it was chosen after load testing showed the obvious
    /// version failing badly. Three properties, in order of importance:
    ///
    /// **Accept eagerly.** Earlier this loop blocked waiting for a free worker before calling
    /// `accept`, so during a burst connections piled up in the kernel's queue — and once that
    /// filled, the kernel *reset* the overflow. 500 simultaneous messages produced hundreds of
    /// transport errors. A reset is the worst way to shed load, because the client cannot tell
    /// "retry, I am busy" from "I am broken". Accepting immediately keeps that queue drained and
    /// moves the decision into this process, where it can be answered properly.
    ///
    /// **Shed with a status code.** Past the queue bound, the connection gets `503` and a
    /// `Retry-After` rather than being dropped. That is a instruction a client can act on.
    ///
    /// **A fixed worker pool, not a thread per request.** Workers block on I/O, so dispatching
    /// each connection onto a concurrent queue would grow one thread per blocked request — the
    /// thread explosion that bounded concurrency was meant to prevent. A fixed set of threads
    /// consuming a bounded queue makes both limits explicit: `maxConcurrent` requests execute at
    /// once, `maxQueued` wait, and everything beyond is refused politely.
    func serve() {
        let pending = NSCondition()
        var queued: [(fd: Int32, peer: String)] = []
        var stopped = false

        for _ in 0..<maxConcurrent {
            let worker = Thread { [weak self] in
                while true {
                    pending.lock()
                    while queued.isEmpty && !stopped { pending.wait() }
                    if stopped && queued.isEmpty { pending.unlock(); return }
                    let job = queued.removeFirst()
                    pending.unlock()

                    guard let self else { close(job.fd); continue }
                    self.applyTimeout(job.fd)
                    self.handleConnection(job.fd, peer: job.peer)
                    close(job.fd)
                }
            }
            worker.stackSize = 512 * 1024
            worker.start()
        }

        while true {
            var peerAddr = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &peerAddr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &length)
                }
            }
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                continue
            }
            let peer = Self.describe(peerAddr)

            pending.lock()
            if queued.count >= maxQueued {
                pending.unlock()
                // Refuse in a way the caller can reason about, then close.
                var response = HTTPResponse.error(503, "server busy, retry shortly")
                response.extraHeaders["Retry-After"] = "1"
                write(clientFD, response)
                close(clientFD)
                continue
            }
            queued.append((clientFD, peer))
            pending.signal()
            pending.unlock()
        }
    }

    private static func describe(_ addr: sockaddr_in) -> String {
        var copy = addr.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    private func applyTimeout(_ fd: Int32) {
        var tv = timeval(tv_sec: Int(readTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func handleConnection(_ fd: Int32, peer: String) {
        guard let request = readRequest(fd, peer: peer) else {
            // Malformed or timed out. Answer rather than hanging up silently, so a
            // misconfigured client sees why.
            write(fd, .error(400, "malformed request"))
            return
        }
        write(fd, handler(request))
    }

    private func readRequest(_ fd: Int32, peer: String) -> HTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        var headerEnd: Int? = nil

        // Phase 1: headers. Capped independently of the body cap — a client that streams
        // headers forever must not be able to grow this buffer without limit.
        let maxHeaderBytes = 16_384
        while headerEnd == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > maxHeaderBytes { return nil }
            headerEnd = Self.findHeaderEnd(buffer)
        }
        guard let end = headerEnd,
              let headerText = String(data: buffer.prefix(end), encoding: .utf8)
        else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines where line.contains(":") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Chunked bodies are refused rather than misparsed: silently treating a chunked body as
        // a literal one would let a caller smuggle content past the size cap.
        if let encoding = headers["transfer-encoding"], encoding.lowercased().contains("chunked") {
            return nil
        }

        let declared = Int(headers["content-length"] ?? "0") ?? 0
        guard declared >= 0, declared <= ModerationLimits.maxRequestBytes else {
            // Signalled as a request rather than nil so the caller can answer 413 specifically.
            return HTTPRequest(method: parts[0], path: parts[1], headers: headers,
                               body: Data("__oversized__".utf8), peer: peer)
        }

        var body = buffer.suffix(from: min(end + 4, buffer.count))
        while body.count < declared {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            body.append(contentsOf: chunk[0..<n])
        }

        return HTTPRequest(method: parts[0], path: parts[1], headers: headers,
                           body: Data(body.prefix(declared)), peer: peer)
    }

    private static func findHeaderEnd(_ data: Data) -> Int? {
        let pattern: [UInt8] = [13, 10, 13, 10]   // \r\n\r\n
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        for i in 0...(bytes.count - 4) where Array(bytes[i..<(i + 4)]) == pattern {
            return i
        }
        return nil
    }

    private func write(_ fd: Int32, _ response: HTTPResponse) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        // One request per connection. Keep-alive would mean tracking connection state and
        // pipelining, and the ingress already pools connections upstream.
        head += "Connection: close\r\n"
        for (name, value) in response.extraHeaders { head += "\(name): \(value)\r\n" }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(response.body)
        out.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default:  return "Status"
        }
    }
}
