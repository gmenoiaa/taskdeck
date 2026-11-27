import SwiftUI
import AppKit

/// Syncing with the user's other Macs over Tailscale: on or off, the pairing secret, the other Macs.
struct SyncSettings: View {
    @Environment(AppStore.self) private var store
    @State private var secret = ""
    @State private var newPeer = ""
    @State private var tailnetName: String?
    @State private var address: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Sync with my other Macs", isOn: $store.syncEnabled)
                LabeledContent("This Mac") {
                    if let address {
                        Text(tailnetName ?? address).textSelection(.enabled)
                    } else {
                        Text("Tailscale is not connected").foregroundStyle(.secondary)
                    }
                }
                if store.syncEnabled {
                    if let problem = store.syncServerProblem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else if let listening = store.syncListening {
                        Text("Other Macs reach this one at \(listening), and only through Tailscale.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Tasks, spaces, goals, standup notes, columns and the settings that follow you are kept the same on every Mac. Each Mac keeps its own repositories, Claude homes, GitHub accounts, agent sessions and window layout. Keys and tokens never leave the Keychain. Both Macs must be awake with TaskDeck open; changes made while apart sync when they meet again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Pairing secret") {
                SecureField("Secret", text: $secret, prompt: Text("The same on every Mac"))
                    .onChange(of: secret) { _, value in
                        Keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), account: PeerAuth.secretAccount)
                        store.applySyncSettings()
                    }
                HStack {
                    Button("Make a New Secret") { secret = PeerAuth.newSecret() }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(secret, forType: .string)
                    }
                    .disabled(secret.isEmpty)
                }
                Text("Make it on one Mac, copy it, and paste it here on the others. Every request between them is signed with it, so a machine on the tailnet without it gets nothing. It is kept in the Keychain, not in the data file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Other Macs") {
                ForEach(store.syncPeers, id: \.self) { peer in
                    PeerRow(peer: peer, status: store.peerStatus[peer]) {
                        store.syncPeers.removeAll { $0 == peer }
                        store.peerStatus[peer] = nil
                        store.save()
                    }
                }
                HStack {
                    TextField("Tailnet name", text: $newPeer, prompt: Text("deskserver or deskserver.your-tailnet.ts.net"))
                        .onSubmit(addPeer)
                    Button("Add", action: addPeer)
                        .disabled(newPeer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Button("Sync Now") { Task { await store.syncNow() } }
                        .disabled(!store.syncEnabled || store.syncPeers.isEmpty)
                    Spacer()
                }
                Text("The name the other Mac has in Tailscale. This Mac syncs with them every two minutes and a few seconds after each change. A Mac that can only be reached, not reach out (one shared into another tailnet), still gets everything when this one syncs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
        .onAppear { secret = Keychain.get(account: PeerAuth.secretAccount) ?? "" }
        .task {
            address = TailscaleAddress.current
            tailnetName = await TailscaleAddress.dnsName()
        }
        .onChange(of: store.syncEnabled) {
            store.save()
            store.applySyncSettings()
        }
    }

    private func addPeer() {
        let peer = newPeer.trimmingCharacters(in: .whitespaces)
        guard !peer.isEmpty, !store.syncPeers.contains(peer) else { return }
        store.syncPeers.append(peer)
        newPeer = ""
        store.save()
        Task { await store.syncNow() }
    }
}

private struct PeerRow: View {
    let peer: String
    let status: PeerStatus?
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status?.name.map { "\($0) — \(peer)" } ?? peer)
                if status?.syncing == true {
                    Text("Syncing…").font(.caption).foregroundStyle(.secondary)
                } else if let error = status?.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
                if let last = status?.lastSynced {
                    Text("Last synced \(last.formatted(date: .omitted, time: .shortened))\(status?.schema.map { " · data version \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                } else if status?.error == nil, status?.syncing != true {
                    Text("Not synced yet").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Stop syncing with this Mac")
        }
    }
}
