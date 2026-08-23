
import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
#if canImport(Security)
import Security
#endif


final class RESPClient {

    struct Configuration {
        var host: String
        var port: Int
        var password: String?
        var timeout: TimeInterval = 2
        var useTLS: Bool = false

        static func from(url: String) -> Configuration? {
            guard let u = URL(string: url),
                  let host = u.host, !host.isEmpty
            else { return nil }
            let scheme = (u.scheme ?? "redis").lowercased()
            guard scheme == "redis" || scheme == "rediss" else { return nil }
            let port = u.port ?? (scheme == "rediss" ? 6380 : 6379)
            let password = u.password?.isEmpty == false ? u.password : nil
            return Configuration(host: host, port: port, password: password,
                                 useTLS: scheme == "rediss")
        }
    }

    private let config: Configuration
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var tls: RedisTLS?

    init(configuration: Configuration) {
        self.config = configuration
    }

    deinit { disconnect() }


    func set(key: String, value: String, ttlSeconds: Int? = nil) throws {
        var args: [String] = ["SET", key, value]
        if let ttl = ttlSeconds { args += ["EX", "\(ttl)"] }
        _ = try command(args)
    }

    func get(key: String) throws -> String? {
        let r = try command(["GET", key])
        if case .bulk(let s) = r { return s }
        return nil
    }

    func del(_ key: String) throws {
        _ = try command(["DEL", key])
    }

    func ping() throws -> Bool {
        let r = try command(["PING"])
        if case .simple(let s) = r { return s == "PONG" }
        return false
    }

    func compareAndSet(key: String, expected: String, value: String, ttlSeconds: Int) throws -> Bool {
        let r = try command(["EVAL", Self.casLua, "1", key, expected, value, "\(ttlSeconds)"])
        if case .integer(let n) = r { return n == 1 }
        return false
    }

    private static let casLua = """
    local cur = redis.call('GET', KEYS[1])
    if not cur then cur = '' end
    if cur ~= ARGV[1] then return 0 end
    if ARGV[2] == '' then
      redis.call('DEL', KEYS[1])
    else
      redis.call('SET', KEYS[1], ARGV[2], 'EX', tonumber(ARGV[3]))
    end
    return 1
    """

    func mutateJSON<T: Codable>(
        key: String,
        ttlSeconds: Int,
        decoder: JSONDecoder,
        encoder: JSONEncoder,
        empty: T,
        isEmpty: (T) -> Bool,
        _ body: (inout T) -> Void
    ) {
        for _ in 0..<32 {
            let raw = (try? get(key: key)) ?? ""
            var state = empty
            if !raw.isEmpty, let data = raw.data(using: .utf8),
               let decoded = try? decoder.decode(T.self, from: data) {
                state = decoded
            }
            body(&state)
            let replacement: String
            if isEmpty(state) {
                replacement = ""
            } else if let data = try? encoder.encode(state),
                      let json = String(data: data, encoding: .utf8) {
                replacement = json
            } else {
                return
            }
            if (try? compareAndSet(key: key, expected: raw, value: replacement,
                                   ttlSeconds: ttlSeconds)) == true {
                return
            }
        }
    }


    enum RESPValue {
        case simple(String)
        case bulk(String?)
        case integer(Int)
        case array([RESPValue])
        case error(String)
    }


    private func connect() throws {
        if fd >= 0 { disconnect() }
        let sock = try tcpConnect(host: config.host, port: config.port, timeout: config.timeout)
        fd = sock
        if config.useTLS {
            do {
                tls = try RedisTLS(fd: sock, host: config.host)
            } catch {
                disconnect()
                throw error
            }
        }
        if let pw = config.password {
            _ = try command(["AUTH", pw], alreadyLocked: true)
        }
    }

    private func disconnect() {
        tls?.close()
        tls = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func ioWrite(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let n: Int
            if let tls {
                n = try tls.write(bytes, offset: sent)
            } else {
                n = bytes.withUnsafeBufferPointer { buf in
                    write(fd, buf.baseAddress! + sent, bytes.count - sent)
                }
            }
            if n <= 0 { disconnect(); throw RESPError.io("write failed") }
            sent += n
        }
    }

    private func ioRead(_ count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n: Int
            if let tls {
                n = try tls.read(&buf, offset: got, max: count - got)
            } else {
                n = buf.withUnsafeMutableBufferPointer { ptr in
                    read(fd, ptr.baseAddress! + got, count - got)
                }
            }
            if n <= 0 { disconnect(); throw RESPError.io("read failed") }
            got += n
        }
        return buf
    }

    private func command(_ args: [String], alreadyLocked: Bool = false) throws -> RESPValue {
        if !alreadyLocked { lock.lock() }
        defer { if !alreadyLocked { lock.unlock() } }

        if fd < 0 { try connect() }

        try ioWrite(Array(encode(args).utf8))
        return try readValue()
    }

    private func encode(_ args: [String]) -> String {
        var s = "*\(args.count)\r\n"
        for a in args { s += "$\(a.utf8.count)\r\n\(a)\r\n" }
        return s
    }

    private func readLine() throws -> String {
        var buf = [UInt8]()
        while true {
            let b = try ioRead(1)[0]
            if b == UInt8(ascii: "\n"), buf.last == UInt8(ascii: "\r") {
                buf.removeLast()
                return String(bytes: buf, encoding: .utf8) ?? ""
            }
            buf.append(b)
            if buf.count > 1_048_576 { throw RESPError.protocol_("line too long") }
        }
    }

    private func readValue() throws -> RESPValue {
        let line = try readLine()
        guard let first = line.first else { throw RESPError.protocol_("empty line") }
        let rest = String(line.dropFirst())
        switch first {
        case "+": return .simple(rest)
        case "-": return .error(rest)
        case ":": return .integer(Int(rest) ?? 0)
        case "$":
            let len = Int(rest) ?? -1
            if len == -1 { return .bulk(nil) }
            let payload = try ioRead(len + 2)
            return .bulk(String(bytes: payload.prefix(len), encoding: .utf8))
        case "*":
            let count = Int(rest) ?? 0
            if count < 0 { return .bulk(nil) }
            var arr: [RESPValue] = []
            for _ in 0..<count { arr.append(try readValue()) }
            return .array(arr)
        default:
            throw RESPError.protocol_("unknown type \(first)")
        }
    }

    enum RESPError: Error, CustomStringConvertible {
        case connection(String)
        case io(String)
        case protocol_(String)
        var description: String {
            switch self {
            case .connection(let s): return "Redis connection: \(s)"
            case .io(let s): return "Redis I/O: \(s)"
            case .protocol_(let s): return "Redis protocol: \(s)"
            }
        }
    }
}

#if canImport(Glibc)
private let posixStream: Int32 = Int32(SOCK_STREAM.rawValue)
#else
private let posixStream: Int32 = SOCK_STREAM
#endif

private func tcpConnect(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = posixStream
    var result: UnsafeMutablePointer<addrinfo>?
    let gai = host.withCString { h in
        String(port).withCString { p in getaddrinfo(h, p, &hints, &result) }
    }
    guard gai == 0, let head = result else {
        throw RESPClient.RESPError.connection("DNS failed for \(host)")
    }
    defer { freeaddrinfo(head) }

    var cursor: UnsafeMutablePointer<addrinfo>? = head
    while let ai = cursor {
        let sock = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        if sock >= 0 {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            if DarwinOrGlibcConnect(sock, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                return sock
            }
            close(sock)
        }
        cursor = ai.pointee.ai_next
    }
    throw RESPClient.RESPError.connection("connect() to \(host):\(port) failed")
}

#if canImport(Glibc)
private func DarwinOrGlibcConnect(_ sock: Int32, _ addr: UnsafePointer<sockaddr>!, _ len: socklen_t) -> Int32 {
    Glibc.connect(sock, addr, len)
}
#else
private func DarwinOrGlibcConnect(_ sock: Int32, _ addr: UnsafePointer<sockaddr>!, _ len: socklen_t) -> Int32 {
    Darwin.connect(sock, addr, len)
}
#endif

final class RedisTLS {
    private let fd: Int32
    #if os(Linux)
    private var ssl: OpaquePointer?
    private var ctx: OpaquePointer?
    #else
    private var context: SSLContext?
    #endif

    init(fd: Int32, host: String) throws {
        self.fd = fd
        #if os(Linux)
        try handshakeLinux(host: host)
        #else
        try handshakeApple(host: host)
        #endif
    }

    func write(_ bytes: [UInt8], offset: Int) throws -> Int {
        let n = bytes.count - offset
        #if os(Linux)
        guard let ssl else { throw RESPClient.RESPError.io("tls not started") }
        return bytes.withUnsafeBufferPointer { buf in
            Int(OpenSSL.SSL_write(ssl, buf.baseAddress! + offset, Int32(n)))
        }
        #else
        var written = 0
        let status = bytes.withUnsafeBufferPointer { buf -> OSStatus in
            SSLWrite(context!, buf.baseAddress! + offset, n, &written)
        }
        if status != errSecSuccess && status != errSSLWouldBlock {
            throw RESPClient.RESPError.io("tls write \(status)")
        }
        return written
        #endif
    }

    func read(_ buf: inout [UInt8], offset: Int, max: Int) throws -> Int {
        #if os(Linux)
        guard let ssl else { throw RESPClient.RESPError.io("tls not started") }
        return buf.withUnsafeMutableBufferPointer { ptr in
            Int(OpenSSL.SSL_read(ssl, ptr.baseAddress! + offset, Int32(max)))
        }
        #else
        var got = 0
        let status = buf.withUnsafeMutableBufferPointer { ptr -> OSStatus in
            SSLRead(context!, ptr.baseAddress! + offset, max, &got)
        }
        if status != errSecSuccess && status != errSSLWouldBlock {
            throw RESPClient.RESPError.io("tls read \(status)")
        }
        return got
        #endif
    }

    func close() {
        #if os(Linux)
        if let ssl { OpenSSL.SSL_shutdown(ssl); OpenSSL.SSL_free(ssl) }
        if let ctx { OpenSSL.SSL_CTX_free(ctx) }
        ssl = nil; ctx = nil
        #else
        if let context { SSLClose(context) }
        context = nil
        #endif
    }

    #if !os(Linux)
    private func handshakeApple(host: String) throws {
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw RESPClient.RESPError.connection("SSLCreateContext failed")
        }
        context = ctx
        SSLSetIOFuncs(ctx, { conn, data, length in
            let fd = Int32(Int(bitPattern: conn))
            let n = Darwin.read(fd, data, length.pointee)
            if n < 0 { return OSStatus(errSSLClosedAbort) }
            length.pointee = n
            return errSecSuccess
        }, { conn, data, length in
            let fd = Int32(Int(bitPattern: conn))
            let n = Darwin.write(fd, data, length.pointee)
            if n < 0 { return OSStatus(errSSLClosedAbort) }
            length.pointee = n
            return errSecSuccess
        })
        SSLSetConnection(ctx, UnsafeMutableRawPointer(bitPattern: Int(fd)))
        _ = host.withCString { SSLSetPeerDomainName(ctx, $0, host.utf8.count) }
        SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        var status = SSLHandshake(ctx)
        var spins = 0
        while spins < 200 {
            if status == errSecSuccess { return }
            if status == errSSLWouldBlock {
                status = SSLHandshake(ctx)
                spins += 1
                continue
            }
            if status == OSStatus(-9841) {
                var trust: SecTrust?
                SSLCopyPeerTrust(ctx, &trust)
                guard let trust else {
                    throw RESPClient.RESPError.connection("Redis TLS: no server trust")
                }
                var cfError: CFError?
                guard SecTrustEvaluateWithError(trust, &cfError) else {
                    throw RESPClient.RESPError.connection("Redis TLS: certificate not trusted")
                }
                status = SSLHandshake(ctx)
                spins += 1
                continue
            }
            throw RESPClient.RESPError.connection("TLS handshake failed (\(status))")
        }
        throw RESPClient.RESPError.connection("TLS handshake timed out")
    }
    #endif

    #if os(Linux)
    private func handshakeLinux(host: String) throws {
        guard OpenSSL.bind() else {
            throw RESPClient.RESPError.connection(
                "rediss:// needs libssl (libssl.so.3). Install it or terminate TLS in a sidecar and use redis://")
        }
        OpenSSL.SSL_library_init()
        guard let c = OpenSSL.SSL_CTX_new(OpenSSL.TLS_client_method()) else {
            throw RESPClient.RESPError.connection("SSL_CTX_new failed")
        }
        ctx = c
        OpenSSL.SSL_CTX_set_default_verify_paths(c)
        OpenSSL.SSL_CTX_set_verify(c, OpenSSL.verifyPeer)
        guard let s = OpenSSL.SSL_new(c) else {
            throw RESPClient.RESPError.connection("SSL_new failed")
        }
        ssl = s
        _ = OpenSSL.SSL_set_fd(s, fd)
        _ = host.withCString { OpenSSL.SSL_set_tlsext_host_name(s, $0) }
        let rc = OpenSSL.SSL_connect(s)
        guard rc == 1 else {
            throw RESPClient.RESPError.connection("SSL_connect failed (\(rc))")
        }
        guard OpenSSL.SSL_get_verify_result(s) == 0 else {
            throw RESPClient.RESPError.connection("Redis TLS: certificate not trusted")
        }
    }
    #endif
}

#if os(Linux)
enum OpenSSL {
    static var handle: UnsafeMutableRawPointer?
    static func bind() -> Bool {
        if handle != nil { return true }
        handle = dlopen("libssl.so.3", RTLD_NOW) ?? dlopen("libssl.so.1.1", RTLD_NOW)
            ?? dlopen("libssl.so", RTLD_NOW)
        return handle != nil
    }

    private static func sym<T>(_ name: String) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static func SSL_library_init() {
        typealias F = @convention(c) () -> Int32
        if let initSSL = sym("OPENSSL_init_ssl") as F? {
            _ = initSSL()
        } else if let legacyInit = sym("SSL_library_init") as F? {
            _ = legacyInit()
        }
        _ = (sym("OPENSSL_init_ssl") as (@convention(c) (UInt64, UnsafeRawPointer?) -> Int32)?)?(0, nil)
    }

    static func TLS_client_method() -> OpaquePointer? {
        typealias F = @convention(c) () -> OpaquePointer?
        return (sym("TLS_client_method") as F?)?()
    }

    static let verifyPeer: Int32 = 0x01 | 0x02 // SSL_VERIFY_PEER | FAIL_IF_NO_PEER_CERT

    static func SSL_CTX_set_verify(_ ctx: OpaquePointer?, _ mode: Int32) {
        typealias CB = @convention(c) (Int32, OpaquePointer?) -> Int32
        typealias F = @convention(c) (OpaquePointer?, Int32, CB?) -> Void
        (sym("SSL_CTX_set_verify") as F?)?(ctx, mode, nil)
    }

    static func SSL_get_verify_result(_ ssl: OpaquePointer?) -> Int {
        typealias F = @convention(c) (OpaquePointer?) -> Int
        return (sym("SSL_get_verify_result") as F?)?(ssl) ?? -1
    }

    static func SSL_CTX_new(_ method: OpaquePointer?) -> OpaquePointer? {
        typealias F = @convention(c) (OpaquePointer?) -> OpaquePointer?
        return (sym("SSL_CTX_new") as F?)?(method)
    }

    static func SSL_CTX_set_default_verify_paths(_ ctx: OpaquePointer?) {
        typealias F = @convention(c) (OpaquePointer?) -> Int32
        _ = (sym("SSL_CTX_set_default_verify_paths") as F?)?(ctx)
    }

    static func SSL_new(_ ctx: OpaquePointer?) -> OpaquePointer? {
        typealias F = @convention(c) (OpaquePointer?) -> OpaquePointer?
        return (sym("SSL_new") as F?)?(ctx)
    }

    static func SSL_set_fd(_ ssl: OpaquePointer?, _ fd: Int32) -> Int32 {
        typealias F = @convention(c) (OpaquePointer?, Int32) -> Int32
        return (sym("SSL_set_fd") as F?)?(ssl, fd) ?? 0
    }

    static func SSL_set_tlsext_host_name(_ ssl: OpaquePointer?, _ name: UnsafePointer<CChar>) -> Int32 {
        typealias F = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Int32
        return (sym("SSL_ctrl") as (@convention(c) (OpaquePointer?, Int32, Int, UnsafePointer<CChar>) -> Int)?)
            .map { Int32($0(ssl, 55 /*SSL_CTRL_SET_TLSEXT_HOSTNAME*/, 0, name)) } ?? 0
    }

    static func SSL_connect(_ ssl: OpaquePointer?) -> Int32 {
        typealias F = @convention(c) (OpaquePointer?) -> Int32
        return (sym("SSL_connect") as F?)?(ssl) ?? 0
    }

    static func SSL_read(_ ssl: OpaquePointer?, _ buf: UnsafeMutableRawPointer?, _ n: Int32) -> Int32 {
        typealias F = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int32) -> Int32
        return (sym("SSL_read") as F?)?(ssl, buf, n) ?? -1
    }

    static func SSL_write(_ ssl: OpaquePointer?, _ buf: UnsafeRawPointer?, _ n: Int32) -> Int32 {
        typealias F = @convention(c) (OpaquePointer?, UnsafeRawPointer?, Int32) -> Int32
        return (sym("SSL_write") as F?)?(ssl, buf, n) ?? -1
    }

    static func SSL_shutdown(_ ssl: OpaquePointer?) {
        typealias F = @convention(c) (OpaquePointer?) -> Int32
        _ = (sym("SSL_shutdown") as F?)?(ssl)
    }

    static func SSL_free(_ ssl: OpaquePointer?) {
        typealias F = @convention(c) (OpaquePointer?) -> Void
        (sym("SSL_free") as F?)?(ssl)
    }

    static func SSL_CTX_free(_ ctx: OpaquePointer?) {
        typealias F = @convention(c) (OpaquePointer?) -> Void
        (sym("SSL_CTX_free") as F?)?(ctx)
    }
}
#endif


public final class RedisActorSignalBackend: ActorSignalBackend {

    private let client: RESPClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let ttl = 86_400   // 24 h — matches the actor store's window

    public init(redisURL: String) throws {
        guard let config = RESPClient.Configuration.from(url: redisURL) else {
            throw ConfigurationError.invalidURL(redisURL)
        }
        self.client = RESPClient(configuration: config)
        self.encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    public func snapshot(sender: String) -> ActorSignalSnapshot? {
        guard let json = try? client.get(key: key(sender)),
              let data = json.data(using: .utf8),
              let s = try? decoder.decode(ActorSignalSnapshot.self, from: data)
        else { return nil }
        return s
    }

    public func mutate(sender: String, _ body: (inout ActorSignalSnapshot) -> Void) {
        client.mutateJSON(
            key: key(sender),
            ttlSeconds: ttl,
            decoder: decoder,
            encoder: encoder,
            empty: ActorSignalSnapshot(),
            isEmpty: { $0.isEmpty },
            body
        )
    }

    public func remove(sender: String) { try? client.del(key(sender)) }
    public func removeAll() { /* Not implemented — would need SCAN */ }

    public var trackedSenderCount: Int { 0 } // requires SCAN; omitted

    public func ping() -> Bool {
        (try? client.ping()) ?? false
    }

    private func key(_ sender: String) -> String { "mod:actor:\(sender)" }

    public enum ConfigurationError: Error {
        case invalidURL(String)
    }
}


public final class RedisConversationBufferBackend: ConversationBufferBackend {

    private let client: RESPClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let ttl = 900   // 15 min — matches the buffer window

    public init(redisURL: String) throws {
        guard let config = RESPClient.Configuration.from(url: redisURL) else {
            throw ConfigurationError.invalidURL(redisURL)
        }
        self.client = RESPClient(configuration: config)
        self.encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    public func snapshot(key: String) -> ConversationBufferSnapshot? {
        guard let json = try? client.get(key: redisKey(key)),
              let data = json.data(using: .utf8),
              let s = try? decoder.decode(ConversationBufferSnapshot.self, from: data)
        else { return nil }
        return s
    }

    public func mutate(key: String, _ body: (inout ConversationBufferSnapshot) -> Void) {
        client.mutateJSON(
            key: redisKey(key),
            ttlSeconds: ttl,
            decoder: decoder,
            encoder: encoder,
            empty: ConversationBufferSnapshot(),
            isEmpty: { $0.isEmpty },
            body
        )
    }

    public func remove(key: String) { try? client.del(redisKey(key)) }
    public func removeAll() { /* requires SCAN */ }

    public func evict(before cutoff: Date, maxConversations: Int) {
    }

    public var trackedCount: Int { 0 } // requires SCAN; omitted

    private func redisKey(_ k: String) -> String { "mod:buf:\(k)" }

    public enum ConfigurationError: Error {
        case invalidURL(String)
    }
}

public final class RedisConversationContextBackend: ConversationContextBackend {

    private let client: RESPClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let ttl = 30 * 86_400

    public init(redisURL: String) throws {
        guard let config = RESPClient.Configuration.from(url: redisURL) else {
            throw RedisActorSignalBackend.ConfigurationError.invalidURL(redisURL)
        }
        self.client = RESPClient(configuration: config)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func snapshot(conversationID: String) -> ConversationContextSnapshot? {
        guard let json = try? client.get(key: key(conversationID)),
              let data = json.data(using: .utf8),
              let s = try? decoder.decode(ConversationContextSnapshot.self, from: data)
        else { return nil }
        return s
    }

    public func mutate(conversationID: String, _ body: (inout ConversationContextSnapshot) -> Void) {
        client.mutateJSON(
            key: key(conversationID),
            ttlSeconds: ttl,
            decoder: decoder,
            encoder: encoder,
            empty: ConversationContextSnapshot(),
            isEmpty: { $0.isEmpty },
            body
        )
    }

    public func remove(conversationID: String) { try? client.del(key(conversationID)) }

    private func key(_ id: String) -> String { "mod:ctx:\(id)" }
}
