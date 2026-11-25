import SwiftUI
import AppKit

/// One space's standup update: written by Claude from the space's facts (or a plain list without a
/// key), editable, and copied to paste into the team's chat. Nothing is posted from here.
struct StandupView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let spaceId: UUID

    @State private var text = ""
    @State private var since = Date()
    /// The start of the period the text was written for; when `since` moves away from it, the
    /// text may be out of date.
    @State private var writtenFor: Date?
    /// How much the facts hold, worked out when the period changes rather than on every redraw:
    /// the facts read cached tickets from disk.
    @State private var summary = ""
    @State private var writing = false
    /// What the writing is doing now: reading the tickets again, or Claude writing.
    @State private var phase: String?
    /// Tickets the tracker did not answer for at the last refresh.
    @State private var refreshNote: String?
    @State private var error: String?
    @State private var copied = false
    /// The text as last saved, to know whether closing has anything to keep.
    @State private var saved = ""
    @State private var writer: Task<Void, Never>?

    private var space: Project? { store.project(spaceId) }

    var body: some View {
        VStack(spacing: 0) {
            if let space {
                content(space)
            } else {
                Text("This space no longer exists.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button("Plain list") { write(plain: true) }
                    .disabled(writing || space == nil)
                    .help("Replace the text with a plain list of the same facts, without Claude")
                Button(writing ? "Writing…" : "Write again") { write() }
                    .disabled(writing || space == nil)
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.cancelAction)
                Button(copied ? "Copied" : "Copy") { copy() }
                    // Return belongs to the text; ⌘Return copies from anywhere in the sheet.
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(writing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .primaryGlass()
                    .help("Copy the update to paste in the team's chat (⌘↩)")
            }
            .actionBar()
        }
        .frame(width: 620, height: 560)
        .onAppear(perform: start)
        .onDisappear { writer?.cancel() }
    }

    private var stale: Bool { writtenFor.map { $0 != since } ?? false }

    private func content(_ space: Project) -> some View {
        // Not `store.now`: it ticks every second, and the sheet has nothing that needs it.
        let now = Date()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(space.color).frame(width: 10, height: 10)
                Text("Standup · \(space.name)").font(.title3.weight(.semibold))
                Spacer()
                if let meeting = space.standup?.meetingFor(now) {
                    Text("Meeting \(StandupSettings.label(meeting, now: now))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                DatePicker("Since", selection: $since, in: ...now, displayedComponents: [.date, .hourAndMinute])
                    .fixedSize()
                    .onChange(of: since) { summarise() }
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if writing {
                    ProgressView().controlSize(.small)
                    if let phase { Text(phase).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            if stale && !writing {
                Label("The period changed. Write again to update the text.", systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let refreshNote, !writing {
                Label(refreshNote, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .disabled(writing)
                .overlay {
                    if text.isEmpty && writing {
                        Text(phase ?? "Writing…").foregroundStyle(.secondary)
                    }
                }
            Text(Claude.apiKey() == nil
                 ? "No Claude API key, so this is a plain list of the facts. Set one in Settings → AI to have Claude write it."
                 : "The space's open tickets are read again from the tracker first. Sent to Claude: this space's tasks, their column, tracker status, time, latest comments, and pull requests with their description. Notes are not sent.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func summarise() {
        guard let space else { return }
        let facts = StandupFacts(space: space, since: since, store: store)
        if facts.isEmpty {
            summary = "Nothing in this space since then"
            return
        }
        var parts = ["\(facts.workedOn.count) worked on", "\(facts.onBoard.count) on the board"]
        let blocked = facts.waiting.filter(\.blocked).count
        if blocked > 0 { parts.append("\(blocked) waiting on others") }
        summary = parts.joined(separator: " · ")
    }

    // MARK: Actions

    /// Shows the update already written for this meeting, or writes one.
    private func start() {
        guard let space, let settings = space.standup else { return }
        Claude.adoptLegacyKey(from: store.projects)
        if let note = store.currentStandup(space) {
            since = note.since
            writtenFor = note.since
            text = note.text
            saved = note.text
            summarise()
        } else {
            since = settings.periodStart(for: Date())
            summarise()
            write()
        }
    }

    /// Reads the space's open tickets again, then writes the update: by Claude, or as a plain list
    /// when asked for one or when there is no API key.
    private func write(plain: Bool = false) {
        guard let space else { return }
        let period = since
        error = nil
        writer?.cancel()
        writer = Task {
            writing = true
            defer {
                writing = false
                phase = nil
            }
            let before = text
            phase = "Reading \(space.kind.label) tickets again…"
            let result = await store.refreshSpace(space.id)
            guard !Task.isCancelled else { return }
            refreshNote = result.failed == 0 ? nil
                : "\(result.failed) of \(result.total) tickets could not be read from \(space.kind.label), so their last saved copy is used."
            summarise()
            let facts = StandupFacts(space: store.project(spaceId) ?? space, since: period, store: store)
            guard !plain, let key = Claude.apiKey() else {
                text = facts.plain
                writtenFor = period
                return
            }
            let request = facts.request(instructions: store.aiInstructions)
            phase = "Claude is writing…"
            text = ""
            do {
                for try await chunk in Claude.stream(apiKey: key, model: store.claudeModel,
                                                     system: request.system, user: request.user) {
                    text += chunk
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                writtenFor = period
                keep()
            } catch is CancellationError {
                text = before
            } catch {
                // The earlier text stays when a new one fails; with none, the plain list stands in.
                text = before.isEmpty ? facts.plain : before
                self.error = "Claude could not write the update: \(error.localizedDescription)"
            }
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        keep()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func close() {
        // Half an answer is not worth keeping: the saved update stays as it was.
        if writing {
            writer?.cancel()
        } else {
            keep()
        }
        dismiss()
    }

    /// Saves the text as the space's update for this meeting, so it opens again as it was and the
    /// next update can build on it.
    private func keep() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != saved else { return }
        store.setStandup(spaceId, StandupNote(text: trimmed, at: Date(), since: writtenFor ?? since))
        saved = trimmed
    }
}

/// Which space's standup sheet is open in the main window.
struct StandupTarget: Identifiable {
    let id: UUID
}
