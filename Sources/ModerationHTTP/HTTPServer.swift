
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
        let backlog = Int32(max(1024, maxConcurrent * 16))
        guard listen(listenFD, backlog) == 0 else {
            close(listenFD)
            throw ServerError.socketFailed("listen() failed — errno \(errno)")
        }
    }

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
            write(fd, .error(400, "malformed request"))
            return
        }
        write(fd, handler(request))
    }

    private func readRequest(_ fd: Int32, peer: String) -> HTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        var headerEnd: Int? = nil

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

        if let encoding = headers["transfer-encoding"], encoding.lowercased().contains("chunked") {
            return nil
        }

        let declared = Int(headers["content-length"] ?? "0") ?? 0
        guard declared >= 0, declared <= ModerationLimits.maxRequestBytes else {
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
