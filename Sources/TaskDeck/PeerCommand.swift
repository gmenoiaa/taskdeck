import Foundation

/// `TaskDeck serve <data.json> [port]` and `TaskDeck sync <data.json> <peer>`: a peer made of a
/// data file, for testing sync on one Mac and for a machine that only holds the data. No window,
/// no notifications, no polling of trackers or agents. The pairing secret comes from
/// TASKDECK_SYNC_SECRET, else from the Keychain.
enum PeerCommand {
    static func runIfAsked(_ arguments: [String]) -> Int32? {
        guard arguments.count > 1, ["serve", "sync"].contains(arguments[1]) else { return nil }
        let secret = ProcessInfo.processInfo.environment["TASKDECK_SYNC_SECRET"]
            ?? Keychain.get(account: PeerAuth.secretAccount) ?? ""
        guard !secret.isEmpty else { print("No pairing secret: set TASKDECK_SYNC_SECRET."); return 2 }
        switch arguments[1] {
        case "serve" where arguments.count >= 3:
            return serve(file: arguments[2], port: arguments.count > 3 ? UInt16(arguments[3]) ?? PeerClient.defaultPort : PeerClient.defaultPort,
                         secret: secret)
        case "sync" where arguments.count == 4:
            return syncOnce(file: arguments[2], peer: arguments[3], secret: secret)
        default:
            print("Usage: TaskDeck serve <data.json> [port] | TaskDeck sync <data.json> <peer>")
            return 2
        }
    }

    /// The file's records, merged with a peer's and written back.
    private actor FilePeer {
        let path: String
        let machine: String
        init(path: String) {
            self.path = path
            // Not this Mac's id: the app on this Mac must see the file as another Mac.
            machine = "file:" + path
        }

        func merge(_ theirs: SyncDocument?) throws -> PeerMessage {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            var snapshot = try AppStore.Snapshot.recordDecoder.decode(AppStore.Snapshot.self, from: data)
            snapshot.schema = snapshot.schema ?? SyncSchema.current
            var reply = PeerMessage(schema: SyncSchema.current, machine: machine, name: "File \(URL(fileURLWithPath: path).lastPathComponent)")
            guard let theirs else { return reply }
            let merged = try SyncMerge.merge(snapshot.document(), theirs)
            let result = try snapshot.applying(merged)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: URL(fileURLWithPath: path), options: .atomic)
            reply.document = merged
            return reply
        }
    }

    private static func serve(file: String, port: UInt16, secret: String) -> Int32 {
        guard let address = TailscaleAddress.current else { print("Tailscale is not connected."); return 1 }
        let peer = FilePeer(path: file)
        let server = PeerServer(host: address, port: port, secret: { secret }, handler: { message in
            do {
                guard message.schema == SyncSchema.current else {
                    throw SyncMerge.Failure.otherSchema(mine: SyncSchema.current, theirs: message.schema)
                }
                let reply = try await peer.merge(message.document)
                print("\(Date().formatted(date: .omitted, time: .standard)) synced with \(message.name)")
                return reply
            } catch {
                print("\(Date().formatted(date: .omitted, time: .standard)) refused \(message.name): \(error.localizedDescription)")
                return PeerMessage(schema: SyncSchema.current, machine: "file:" + file, name: "File", error: error.localizedDescription)
            }
        })
        server.onStateChange = { problem in if let problem { print(problem); exit(1) } }
        do { try server.start() } catch { print(error.localizedDescription); return 1 }
        print("Serving \(file) at \(address):\(port)")
        dispatchMain()
    }

    private static func syncOnce(file: String, peer: String, secret: String) -> Int32 {
        let done = DispatchSemaphore(value: 0)
        let status = Status()
        Task {
            do {
                let local = FilePeer(path: file)
                let data = try Data(contentsOf: URL(fileURLWithPath: file))
                let snapshot = try AppStore.Snapshot.recordDecoder.decode(AppStore.Snapshot.self, from: data)
                let message = PeerMessage(schema: SyncSchema.current, machine: "file:" + file, name: "File",
                                          document: snapshot.document())
                let reply = try await PeerClient.send(message, to: peer, secret: secret)
                _ = try await local.merge(reply.document)
                print("Synced \(file) with \(reply.name).")
            } catch {
                print("Not synced: \(error.localizedDescription)")
                status.code = 1
            }
            done.signal()
        }
        done.wait()
        return status.code
    }

    private final class Status: @unchecked Sendable { var code: Int32 = 0 }
}
