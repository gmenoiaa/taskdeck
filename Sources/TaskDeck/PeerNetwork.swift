import Foundation
import Network

/// A small HTTP/1.1 exchange over the Network framework: one request, one answer, then the
/// connection closes. Plain HTTP inside the tailnet, which encrypts it; the Network framework is
/// used rather than URLSession because App Transport Security refuses plain HTTP to a tailnet name.
enum PeerHTTP {
    static let path = "/sync"
    /// Far above a real data file, so a broken or hostile peer cannot fill the memory.
    static let maxBody = 32 * 1024 * 1024
    static let timeout: TimeInterval = 30

    struct Message {
        var head: String
        var headers: [String: String]
        var body: Data

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    /// The message in `buffer`, or nil while it is still incomplete. Throws when it cannot be one.
    static func parse(_ buffer: Data) throws -> Message? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 64 * 1024 { throw ToolFailure.failed("Header too long.") }
            return nil
        }
        guard let text = String(data: buffer[..<end.lowerBound], encoding: .utf8) else {
            throw ToolFailure.failed("Header is not text.")
        }
        var lines = text.components(separatedBy: "\r\n")
        let head = lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBody else { throw ToolFailure.failed("Body too large.") }
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        return Message(head: head, headers: headers, body: Data(body.prefix(length)))
    }

    static func encode(head: String, headers: [String: String], body: Data) -> Data {
        var lines = [head]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { lines.append("\(name): \(value)") }
        lines.append("Content-Length: \(body.count)")
        lines.append("Connection: close")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }

    /// Reads from `connection` until a whole message has arrived.
    static func receive(_ connection: NWConnection, buffer: Data = Data(),
                        completion: @escaping @Sendable (Result<Message, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            do {
                if let message = try parse(buffer) { return completion(.success(message)) }
            } catch {
                return completion(.failure(error))
            }
            if let error { return completion(.failure(error)) }
            if done { return completion(.failure(ToolFailure.failed("The connection closed before the message was complete."))) }
            receive(connection, buffer: buffer, completion: completion)
        }
    }
}

/// Answers other Macs. Listens only on this Mac's Tailscale address, so the local network cannot
/// reach it, takes connections only from Tailscale addresses, and answers only signed requests.
/// Plain BSD sockets: a Network framework listener on the Tailscale address saw connections
/// arrive but never completed them, while a socket listener on the same address works.
final class PeerServer: @unchecked Sendable {
    typealias Handler = @Sendable (PeerMessage) async -> PeerMessage

    let host: String
    let port: UInt16
    private let secret: @Sendable () -> String?
    private let handler: Handler
    private let queue = DispatchQueue(label: "local.taskdeck.peer-server")
    private let seen = SeenRequests()
    private var socket: Int32 = -1
    private var source: DispatchSourceRead?

    var onStateChange: (@Sendable (String?) -> Void)?

    init(host: String, port: UInt16, secret: @escaping @Sendable () -> String?, handler: @escaping Handler) {
        self.host = host
        self.port = port
        self.secret = secret
        self.handler = handler
    }

    func start() throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw ToolFailure.failed("“\(host)” is not an IPv4 address.") }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ToolFailure.failed("No socket: \(String(cString: strerror(errno))).") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw ToolFailure.failed("Cannot listen on \(host):\(port): \(reason).")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        socket = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptWaiting() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        onStateChange?(nil)
    }

    func stop() {
        source?.cancel()
        source = nil
        socket = -1
    }

    private func acceptWaiting() {
        while true {
            var remote = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(socket, $0, &length) }
            }
            guard client >= 0 else { return }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &remote.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
            guard TailscaleAddress.isTailscale(String(cString: text)) else {
                close(client)
                continue
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.serve(client) }
        }
    }

    /// Reads one request with a deadline, answers it, closes. Runs on its own thread: the socket blocks.
    private func serve(_ client: Int32) {
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: Int(PeerHTTP.timeout), tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let deadline = Date().addingTimeInterval(PeerHTTP.timeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var request: PeerHTTP.Message?
        do {
            while request == nil, Date() < deadline {
                let count = read(client, &chunk, chunk.count)
                if count <= 0 { break }
                buffer.append(chunk, count: count)
                request = try PeerHTTP.parse(buffer)
            }
        } catch {
            request = nil
        }
        guard let request else {
            write(client, status: "400 Bad Request", message: nil, answering: nil)
            return
        }
        let finished = DispatchSemaphore(value: 0)
        Task {
            await self.handle(request, on: client)
            finished.signal()
        }
        finished.wait()
    }

    private func handle(_ request: PeerHTTP.Message, on client: Int32) async {
        guard request.head.hasPrefix("POST \(PeerHTTP.path) ") else {
            return write(client, status: "404 Not Found", message: nil, answering: nil)
        }
        guard let secret = secret(), let time = request.header(PeerAuth.timeHeader),
              let signature = request.header(PeerAuth.signatureHeader),
              let nonce = request.header(PeerAuth.nonceHeader), nonce.count >= 16,
              PeerAuth.verify(secret: secret, method: "POST", path: PeerHTTP.path, time: time,
                              body: request.body, signature: signature, nonce: nonce),
              seen.firstTime(signature) else {
            // No detail: a stranger learns nothing from the refusal.
            return write(client, status: "401 Unauthorized", message: nil, answering: nil)
        }
        guard let message = try? AppStore.Snapshot.recordDecoder.decode(PeerMessage.self, from: request.body) else {
            return write(client, status: "400 Bad Request", message: nil, answering: nil)
        }
        let answer = await handler(message)
        write(client, status: "200 OK", message: answer, answering: signature)
    }

    private func write(_ client: Int32, status: String, message: PeerMessage?, answering request: String?) {
        defer { close(client) }
        let body = message.flatMap { try? AppStore.Snapshot.recordEncoder.encode($0) } ?? Data()
        var headers = ["Content-Type": "application/json"]
        if let request, let secret = secret() {
            let time = String(Int(Date().timeIntervalSince1970))
            headers[PeerAuth.timeHeader] = time
            headers[PeerAuth.signatureHeader] = PeerAuth.signature(secret: secret, method: "200", path: PeerHTTP.path,
                                                                   time: time, body: body, answering: request)
        }
        let data = PeerHTTP.encode(head: "HTTP/1.1 \(status)", headers: headers, body: body)
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(client, raw.baseAddress! + sent, raw.count - sent)
                if count <= 0 { break }
                sent += count
            }
        }
    }
}

/// Asks another Mac.
enum PeerClient {
    static let defaultPort: UInt16 = 47621

    /// "host" or "host:port", as typed in the settings.
    static func endpoint(_ peer: String) -> (host: String, port: UInt16) {
        let text = peer.trimmingCharacters(in: .whitespaces)
        if let colon = text.lastIndex(of: ":"), !text.contains("::"), let port = UInt16(text[text.index(after: colon)...]) {
            return (String(text[..<colon]), port)
        }
        return (text, defaultPort)
    }

    /// Sends `message` and returns the other Mac's answer, after checking that the answer is
    /// signed with the same secret and answers this very request.
    static func send(_ message: PeerMessage, to peer: String, secret: String) async throws -> PeerMessage {
        let (host, port) = endpoint(peer)
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ToolFailure.failed("“\(peer)” is not a name or address.")
        }
        let body = try AppStore.Snapshot.recordEncoder.encode(message)
        let time = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString
        let signature = PeerAuth.signature(secret: secret, method: "POST", path: PeerHTTP.path, time: time, body: body, nonce: nonce)
        let request = PeerHTTP.encode(head: "POST \(PeerHTTP.path) HTTP/1.1",
                                      headers: ["Host": host, "Content-Type": "application/json",
                                                PeerAuth.timeHeader: time, PeerAuth.signatureHeader: signature,
                                                PeerAuth.nonceHeader: nonce],
                                      body: body)
        let answer = try await exchange(request, host: host, port: nwPort)

        let status = answer.head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        switch status {
        case "200": break
        case "401": throw ToolFailure.failed("\(host) refused the pairing secret. Both Macs need the same one.")
        default: throw ToolFailure.failed("\(host) answered “\(answer.head)”.")
        }
        guard let answerTime = answer.header(PeerAuth.timeHeader), let answerSignature = answer.header(PeerAuth.signatureHeader),
              PeerAuth.verify(secret: secret, method: "200", path: PeerHTTP.path, time: answerTime, body: answer.body,
                              signature: answerSignature, answering: signature) else {
            throw ToolFailure.failed("The answer from \(host) was not signed with the pairing secret.")
        }
        let reply = try AppStore.Snapshot.recordDecoder.decode(PeerMessage.self, from: answer.body)
        if let error = reply.error { throw ToolFailure.failed(error) }
        return reply
    }

    private static func exchange(_ request: Data, host: String, port: NWEndpoint.Port) async throws -> PeerHTTP.Message {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "local.taskdeck.peer-client")
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            func finish(_ result: Result<PeerHTTP.Message, Error>) {
                guard once.first() else { return }
                connection.cancel()
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error { finish(.failure(error)) }
                    })
                    PeerHTTP.receive(connection) { finish($0) }
                case .failed(let error):
                    finish(.failure(ToolFailure.failed("Could not reach \(host): \(error.localizedDescription)")))
                case .waiting(let error):
                    finish(.failure(ToolFailure.failed("Could not reach \(host): \(error.localizedDescription)")))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + PeerHTTP.timeout) {
                finish(.failure(ToolFailure.failed("\(host) did not answer in time.")))
            }
        }
    }

    /// The continuation must be resumed exactly once, whichever of answer, failure or timeout comes first.
    private final class Once: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
