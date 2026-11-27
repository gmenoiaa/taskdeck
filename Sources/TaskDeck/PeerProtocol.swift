import Foundation
import CryptoKit


/// What two Macs say to each other: who is speaking and, for a sync, its records.
struct PeerMessage: Codable {
    /// `SyncSchema.current` of the sender. Peers of different versions do not sync.
    var schema: Int
    /// `Machine.id` of the sender, so a Mac never syncs with itself by mistake.
    var machine: String
    /// The sender's name for people: "Geiser's MacBook Pro".
    var name: String
    var document: SyncDocument?
    /// Set on a refusal, in words for the settings.
    var error: String?
}

/// Every request and answer is signed with the pairing secret both Macs hold. Being on the
/// tailnet is not enough: other people's machines can be on it too. Tailscale already encrypts
/// the traffic; the signature proves it came from a paired Mac and was not changed or replayed.
enum PeerAuth {
    static let secretAccount = "sync-secret"
    /// How far apart the two clocks and the trip may be. A request older than this is refused,
    /// and one seen within it is refused a second time.
    static let window: TimeInterval = 120

    static let timeHeader = "X-TaskDeck-Time"
    static let signatureHeader = "X-TaskDeck-Signature"
    /// A random value per request, so two requests with the same body in the same second still
    /// differ, and the replay check does not mistake the second for a copy.
    static let nonceHeader = "X-TaskDeck-Nonce"

    /// A new secret: 32 random bytes, written so it can be pasted on the other Mac.
    static func newSecret() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    /// Signs what cannot be changed without notice: the method, the path, the time, the body, and
    /// for an answer the signature of the request it answers, so an answer cannot be replayed
    /// to another request.
    static func signature(secret: String, method: String, path: String, time: String, body: Data,
                          nonce: String = "", answering request: String? = nil) -> String {
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let text = [method, path, time, nonce, digest, request ?? ""].joined(separator: "\n")
        let code = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return Data(code).base64EncodedString()
    }

    /// Whether `signature` is right, compared in constant time, and `time` is recent.
    static func verify(secret: String, method: String, path: String, time: String, body: Data,
                       signature: String, nonce: String = "", answering request: String? = nil, now: Date = Date()) -> Bool {
        guard let seconds = TimeInterval(time), abs(now.timeIntervalSince1970 - seconds) <= window,
              let given = Data(base64Encoded: signature) else { return false }
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let text = [method, path, time, nonce, digest, request ?? ""].joined(separator: "\n")
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: Data(text.utf8),
                                                      using: SymmetricKey(data: Data(secret.utf8)))
    }
}

/// Requests already seen within the time window: the same signed request twice is a replay.
final class SeenRequests: @unchecked Sendable {
    private var seen: [String: Date] = [:]
    private let lock = NSLock()

    /// False when the signature was seen within the window.
    func firstTime(_ signature: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        seen = seen.filter { now.timeIntervalSince($0.value) <= PeerAuth.window * 2 }
        guard seen[signature] == nil else { return false }
        seen[signature] = now
        return true
    }
}

/// This Mac's Tailscale address, read from the network interfaces: an IPv4 address in
/// 100.64.0.0/10, the range Tailscale gives its machines. Nil when Tailscale is not connected.
enum TailscaleAddress {
    static var current: String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr.bigEndian }
            // 100.64.0.0/10
            if ip & 0xFFC0_0000 == 0x6440_0000 {
                return "\(ip >> 24).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
            }
        }
        return nil
    }

    /// Whether an address a request came from is a Tailscale one (IPv4 100.64.0.0/10 or IPv6 fd7a:115c:a1e0::/48).
    static func isTailscale(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 { return parts[0] == 100 && (64...127).contains(parts[1]) }
        return host.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }

    /// This Mac's name in the tailnet ("geisers-macbook-pro.taild702ef.ts.net"), from the
    /// Tailscale command. Nil when it is not installed or not connected.
    static func dnsName() async -> String? {
        let paths = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        guard let tool = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let reply = try? await Shell.run(tool, ["status", "--json", "--peers=false"], timeout: 10), reply.status == 0,
              let json = (try? JSONSerialization.jsonObject(with: reply.out)) as? [String: Any],
              let me = json["Self"] as? [String: Any], let name = me["DNSName"] as? String else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }
}
