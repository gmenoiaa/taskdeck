import Foundation

/// How syncing with one of the other Macs went, for the settings.
struct PeerStatus: Equatable {
    /// The other Mac's own name, once it answered.
    var name: String?
    var lastSynced: Date?
    var schema: Int?
    var error: String?
    var syncing = false
}

/// Syncing with the user's other Macs over Tailscale. Each sync is one round trip: this Mac sends
/// its records, the other merges them into its own, saves, and sends back the result, which this
/// Mac merges with whatever changed meanwhile. Both end up the same, and a Mac that can only be
/// reached (not reach out) still gets everything when the other one syncs.
extension AppStore {
    static let syncEvery: Duration = .seconds(120)
    /// After a change, a short wait gathers the next few changes into one sync.
    static let syncDelay: Duration = .seconds(3)

    var syncSecret: String? {
        let secret = Keychain.get(account: PeerAuth.secretAccount)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return secret.isEmpty ? nil : secret
    }

    var machineName: String { Host.current().localizedName ?? "Mac" }

    /// Starts or stops listening and the periodic sync to match the settings. Called at launch and
    /// whenever the sync settings change.
    func applySyncSettings() {
        peerServer?.stop()
        peerServer = nil
        syncLoop?.cancel()
        syncLoop = nil
        syncListening = nil
        guard syncEnabled else { syncServerProblem = nil; return }
        guard saveBlocked == nil else { syncServerProblem = "This Mac is not saving its data, so it does not sync either."; return }
        guard syncSecret != nil else { syncServerProblem = "Set the pairing secret to sync."; return }
        guard let address = TailscaleAddress.current else {
            syncServerProblem = "Tailscale is not connected on this Mac."
            return
        }
        let server = PeerServer(host: address, port: PeerClient.defaultPort,
                                secret: { Keychain.get(account: PeerAuth.secretAccount)?.trimmingCharacters(in: .whitespacesAndNewlines) },
                                handler: { [weak self] message in
                                    await self?.answer(message) ?? PeerMessage(schema: SyncSchema.current, machine: "", name: "", error: "Not ready.")
                                })
        server.onStateChange = { [weak self] problem in
            Task { @MainActor in
                self?.syncServerProblem = problem
                self?.syncListening = problem == nil ? "\(address):\(PeerClient.defaultPort)" : nil
            }
        }
        do {
            try server.start()
            peerServer = server
            syncServerProblem = nil
        } catch {
            syncServerProblem = "Could not listen on \(address): \(error.localizedDescription)"
        }
        syncLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: Self.syncEvery)
            }
        }
    }

    /// Whether the records differ from what the other Macs last got, so a save is worth a sync.
    func changedSinceSync(_ records: [String: Data]) -> Bool {
        syncEnabled && !syncPeers.isEmpty && records != syncedRecords
    }

    /// A sync shortly after a change; another change before it starts moves it back.
    func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.syncDelay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Syncs with every peer in turn. A peer that cannot be reached keeps its last success and
    /// shows why; the next round tries again.
    func syncNow() async {
        guard syncEnabled, saveBlocked == nil, let secret = syncSecret else { return }
        for peer in syncPeers {
            var status = peerStatus[peer] ?? PeerStatus()
            guard !status.syncing else { continue }
            status.syncing = true
            peerStatus[peer] = status
            do {
                let message = PeerMessage(schema: SyncSchema.current, machine: Machine.id, name: machineName,
                                          document: currentDocument())
                let reply = try await PeerClient.send(message, to: peer, secret: secret)
                try check(reply)
                if let theirs = reply.document { try mergeIn(theirs) }
                status.name = reply.name
                status.schema = reply.schema
                status.lastSynced = Date()
                status.error = nil
            } catch {
                status.error = error.localizedDescription
            }
            status.syncing = false
            peerStatus[peer] = status
        }
    }

    /// The records as they stand, after saving anything not saved yet so it carries its stamp.
    private func currentDocument() -> SyncDocument {
        save()
        let document = makeSnapshot().document()
        syncedRecords = document.records
        return document
    }

    /// Refuses a peer that is this same Mac or another data version, in words for the settings.
    private func check(_ message: PeerMessage) throws {
        if message.machine == Machine.id {
            throw ToolFailure.failed("That is this Mac. Add the other Mac's tailnet name.")
        }
        if message.schema != SyncSchema.current {
            throw SyncMerge.Failure.otherSchema(mine: SyncSchema.current, theirs: message.schema)
        }
    }

    /// Another Mac's request, answered with the merged records.
    func answer(_ message: PeerMessage) -> PeerMessage {
        var reply = PeerMessage(schema: SyncSchema.current, machine: Machine.id, name: machineName)
        guard syncEnabled else { reply.error = "Sync is turned off on \(machineName)."; return reply }
        guard saveBlocked == nil else { reply.error = "\(machineName) is not saving its data."; return reply }
        do {
            try check(message)
            if let theirs = message.document {
                reply.document = try mergeIn(theirs)
                syncedRecords = savedRecords
            }
        } catch {
            reply.error = error.localizedDescription
        }
        return reply
    }

    /// Merges another Mac's records into this Mac's and puts the result in place. What came in is
    /// saved with the other Mac's stamps, not as a change made here, so it is not sent back as new.
    @discardableResult
    func mergeIn(_ theirs: SyncDocument) throws -> SyncDocument {
        save()
        let snapshot = makeSnapshot()
        let mine = snapshot.document()
        let merged = try SyncMerge.merge(mine, theirs)
        guard merged != mine else { return merged }
        let result = try snapshot.applying(merged)
        applyingSync = true
        defer { applyingSync = false }
        adopt(result)
        save()
        return makeSnapshot().document()
    }
}
