import SwiftUI
import AppKit

/// Ticket data fetched live from the tracker (Redmine, Jira or GitHub).
struct IssueDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskId: UUID

    @State private var detail: TicketDetail?
    @State private var myEntries: [RedmineClient.SpentEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var entriesError: String?
    enum Tab { case ticket, comments, time, notes }
    @State private var tab = Tab.ticket
    @State private var showLog = false
    @State private var showSession = false
    @State private var copied = false
    @State private var newComment = ""
    @State private var posting = false
    @State private var postError: String?
    @State private var explanation = ""
    @State private var notes = ""
    @State private var notesLoaded = false
    @State private var explaining = false
    @State private var explainError: String?
    @State private var explainCopied = false

    private var task: TaskItem? { store.task(taskId) }
    private var project: Project? { store.project(task?.projectId) }
    private var isRedmine: Bool { project?.kind == .redmine }
    private var myHours: Double { myEntries.reduce(0) { $0 + $1.hours } }
    private var comments: [TicketDetail.Comment] {
        (detail?.comments ?? []).filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("View", selection: $tab) {
                Text("Ticket").tag(Tab.ticket)
                Text(detail == nil ? "Comments" : "Comments (\(comments.count))").tag(Tab.comments)
                Text("Time").tag(Tab.time)
                Text("Notes").tag(Tab.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error, tab == .ticket || tab == .comments {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    switch tab {
                    case .ticket:
                        // Shown even when the ticket cannot be fetched: the sessions are saved here.
                        if let task, !store.sessions(of: task).isEmpty {
                            section("Agent sessions") { SessionsList(taskId: taskId) }
                        }
                        if let detail {
                            meta(detail)
                            if explaining || !explanation.isEmpty || explainError != nil { explanationBox }
                            section("Description") {
                                let text = detail.description.trimmingCharacters(in: .whitespacesAndNewlines)
                                if detail.markdown && !text.isEmpty {
                                    MarkdownView(text: text)
                                } else {
                                    Text(text.isEmpty ? "No description." : text)
                                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        } else if loading {
                            loadingView
                        }
                    case .comments:
                        if let detail {
                            composer
                            if comments.isEmpty {
                                Text("No comments.").foregroundStyle(.secondary)
                            }
                            ForEach(comments.reversed()) { c in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(c.author).font(.callout.weight(.semibold))
                                        Spacer()
                                        Text(c.date).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if detail.markdown {
                                        MarkdownView(text: c.body)
                                    } else {
                                        Text(c.body).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(10)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            }
                        } else if loading {
                            loadingView
                        }
                    case .time:
                        // Tracked in this app: available even when the ticket cannot be fetched.
                        timeSection
                        if isRedmine, let detail { hoursSection(detail) }
                    case .notes:
                        notesSection
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .softScrollEdges()
            .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { Task { await load() } } label: {
                    HStack(spacing: 6) {
                        // The spinner takes the icon's place while loading.
                        ZStack {
                            Image(systemName: "arrow.clockwise").opacity(loading ? 0 : 1)
                            if loading { ProgressView().controlSize(.small) }
                        }
                        Text("Refresh")
                    }
                }
                .disabled(loading)
                if let task, !task.url.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(task.url, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link")
                    }
                }
                Button { Task { await explain() } } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Image(systemName: "sparkles").opacity(explaining ? 0 : 1)
                            if explaining { ProgressView().controlSize(.small) }
                        }
                        Text(explanation.isEmpty ? "Explain" : "Explain again")
                    }
                }
                .disabled(explaining || detail == nil)
                .help("Ask Claude to explain this ticket in simple words (ASD-STE100 style)")
                if Orca.isInstalled {
                    Button { showSession = true } label: {
                        Label("Start session", systemImage: "terminal")
                    }
                    // Wait for the ticket so the agent gets its full text, not only the title.
                    .disabled(loading)
                    .help("Start an agent on this ticket in a new Orca worktree")
                }
                Spacer()
                if isRedmine {
                    Button("Log time…") { showLog = true }
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .actionBar()
            }
        }
        .frame(width: 640, height: 640)
        .task {
            explanation = task?.explanation ?? ""
            notes = task?.notes ?? ""
            notesLoaded = true
            await load()
        }
        .sheet(isPresented: $showLog, onDismiss: { Task { await load() } }) {
            LogTimeView(taskId: taskId).environment(store)
        }
        .sheet(isPresented: $showSession) {
            StartSessionView(taskId: taskId, detail: detail).environment(store)
        }
    }

    private var loadingView: some View {
        ProgressView("Loading from \(project?.kind.label ?? "tracker")…")
            .frame(maxWidth: .infinity).padding(.top, 60)
    }

    /// Private notes about the task. They stay on this Mac and are never posted to the tracker.
    private var notesSection: some View {
        section("My notes") {
            TextEditor(text: $notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 70, maxHeight: 200)
                .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.yellow.opacity(0.35)))
                .onChange(of: notes) {
                    if notesLoaded { store.setNotes(taskId, notes) }
                }
            Text("Private: saved only on this Mac, not posted to \(project?.kind.label ?? "the tracker") and not sent to the AI.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Claude's plain-language version of the ticket, streamed in as it is written.
    private var explanationBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("In simple words").font(.headline)
                Spacer()
                if !explanation.isEmpty && !explaining {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(explanation, forType: .string)
                        explainCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            explainCopied = false
                        }
                    } label: {
                        Label(explainCopied ? "Copied" : "Copy", systemImage: explainCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .foregroundStyle(Theme.accent)
            if let explainError {
                Label(explainError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if !explanation.isEmpty {
                MarkdownView(text: explanation)
            } else if explaining {
                Text("Claude is reading the ticket…").foregroundStyle(.secondary)
            }
            if !explanation.isEmpty && !explaining {
                Text("Written by Claude from the ticket text. Check the original before you act on it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Theme.accent.opacity(0.25)))
    }

    private func explain() async {
        guard let task, let detail else { return }
        tab = .ticket
        Claude.adoptLegacyKey(from: store.projects)
        guard let key = Claude.apiKey() else {
            explainError = "Set your Claude API key in Settings → AI (⌘,)."
            return
        }
        explaining = true
        explainError = nil
        let previous = explanation
        explanation = ""
        defer { explaining = false }
        do {
            let ticket = Claude.ticketText(task: task, project: project, detail: detail)
            let system = Claude.system(Claude.explainSystem, custom: store.aiInstructions)
            for try await chunk in Claude.stream(apiKey: key, model: store.claudeModel, system: system, user: ticket) {
                explanation += chunk
            }
            store.setExplanation(taskId, explanation)
        } catch {
            // Keep whatever was there before a failed attempt.
            if explanation.isEmpty { explanation = previous }
            explainError = "Could not get an explanation: \(error.localizedDescription)"
        }
    }

    private var formatHint: String {
        switch project?.kind {
        case .github: return "Markdown"
        case .jira: return "Jira wiki markup"
        case .redmine: return project?.textFormat == "markdown" ? "Markdown" : "Textile"
        default: return ""
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $newComment)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 70, maxHeight: 160)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                .disabled(posting)
            HStack {
                Text("Posts as you on \(project?.kind.label ?? "tracker") · \(formatHint)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if posting { ProgressView().controlSize(.small) }
                Button("Comment") { Task { await postComment() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(posting || newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Post comment (⌘↩)")
            }
            if let postError {
                Text(postError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private func postComment() async {
        guard let task, let project else { return }
        let text = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        posting = true
        postError = nil
        do {
            try await TicketFetcher.postComment(project: project, ref: task.ref, url: task.url, text: text)
            newComment = ""
            posting = false
            await load()
        } catch {
            posting = false
            postError = "Could not post: \(error.localizedDescription)"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let project {
                    Text(project.name).font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(project.color.opacity(0.18), in: Capsule())
                        .foregroundStyle(project.color)
                }
                Text([detail?.kindLabel, task?.displayRef].compactMap { $0 }.joined(separator: " "))
                    .font(.callout).foregroundStyle(.secondary)
                if let status = detail?.status {
                    Text(status).font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
            }
            Text(detail?.subject ?? task?.title ?? "").font(.title3.weight(.semibold))
                .textSelection(.enabled)
        }
        .padding(16)
    }

    private func meta(_ detail: TicketDetail) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                            GridItem(.flexible(), alignment: .topLeading)], spacing: 6) {
            ForEach(detail.meta, id: \.0) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text(item.0).foregroundStyle(.secondary)
                    Text(item.1).textSelection(.enabled)
                }
                .font(.callout)
            }
        }
    }

    private func hoursSection(_ detail: TicketDetail) -> some View {
        section("Hours on Redmine") {
            HStack(spacing: 10) {
                stat("Mine on Redmine", String(format: "%.2f h", myHours))
                stat("Issue total", detail.totalSpentHours.map { String(format: "%.2f h", $0) } ?? "—")
                stat("Estimated", detail.estimatedHours.map { String(format: "%.2f h", $0) } ?? "—")
                stat("In app, to log", Fmt.hours(task?.unloggedSeconds ?? 0) + " h",
                     highlight: (task?.unloggedSeconds ?? 0) >= 60)
            }
            if let entriesError {
                Text(entriesError).font(.caption).foregroundStyle(.red)
            }
            if !myEntries.isEmpty {
                VStack(spacing: 0) {
                    ForEach(myEntries) { e in
                        HStack {
                            Text(RedmineDate.prettyDay(e.spent_on)).frame(width: 110, alignment: .leading)
                            Text(e.activity?.name ?? "").foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading).lineLimit(1)
                            Text(e.comments ?? "").lineLimit(1).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.2f h", e.hours)).monospacedDigit()
                        }
                        .font(.callout)
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
    }

    /// Stretches tracked in this app. Each stop of the timer adds one; each is logged on its own.
    private var timeSection: some View {
        section("Time tracked here — \(Fmt.short(task?.total(now: store.now) ?? 0))") {
            TimeEntriesList(taskId: taskId)
            Text("Each stop of the timer adds an entry. Change the start time if you forgot to start the timer.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(highlight ? Color.orange : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func load() async {
        guard let task, let project else { return }
        loading = true
        error = nil
        entriesError = nil
        defer { loading = false }
        do {
            let fetched = try await TicketFetcher.fetch(project: project, ref: task.ref, url: task.url)
            detail = fetched
            store.setRemote(taskId, from: fetched)
            if task.title.isEmpty, var updated = store.task(taskId) {
                updated.title = fetched.subject
                store.upsert(updated)
            }
        } catch {
            self.error = "Could not fetch the ticket: \(error.localizedDescription)"
            return
        }
        guard project.kind == .redmine, let id = Int(task.ref), let client = RedmineClient(project: project) else { return }
        do {
            myEntries = try await client.myTimeEntries(issueId: id)
        } catch {
            entriesError = "Could not fetch your hours: \(error.localizedDescription)"
        }
    }
}
