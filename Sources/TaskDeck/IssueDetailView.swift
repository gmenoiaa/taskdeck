import SwiftUI
import AppKit

/// Ticket data fetched live from the tracker (Redmine, Jira or GitHub).
struct IssueDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskId: UUID

    @State private var detail: TicketDetail?
    @State private var myEntries: [RedmineClient.SpentEntry] = []
    // True from the start, so the sheet opens on the spinner and not on a half-filled screen.
    @State private var loading = true
    @State private var error: String?
    @State private var entriesError: String?
    enum Tab { case ticket, comments, sessions, pullRequests, time, notes }
    @State private var tab = Tab.ticket
    @State private var showLog = false
    @State private var showSession = false
    @State private var editing: TaskItem?
    @State private var confirmDelete = false
    @State private var copied = false
    @State private var newComment = ""
    @State private var posting = false
    @State private var postError: String?
    @State private var explanation = ""
    @State private var explaining = false
    @State private var explainError: String?
    @State private var explainCopied = false
    /// What the status and assignee can be changed to; nil until read, or when it cannot be.
    @State private var options: TicketOptions?
    @State private var optionsError: String?
    @State private var changing = false
    @State private var changeError: String?
    @State private var showEstimates = false
    @State private var pickingDue = false
    @State private var pickingReminder = false
    @State private var estimateText = ""
    @State private var devEstimateText = ""
    @State private var savingEstimates = false
    @State private var estimateError: String?
    @State private var suggestingEstimate = false
    @State private var estimateWhy: String?
    /// Which field the 40% rule filled in ("estimate" or "dev"), and with what. A field I filled
    /// keeps following the other one; a field the user typed in is left alone.
    @State private var derivedField: String?
    @State private var derivedText = ""
    /// A status the tracker refused, with the one the ticket can be taken through first.
    @State private var detour: (target: TrackerChoice, via: TrackerChoice)?

    private var task: TaskItem? { store.task(taskId) }
    private var project: Project? { store.project(task?.projectId) }
    private var isRedmine: Bool { project?.kind == .redmine }
    private var myHours: Double { myEntries.reduce(0) { $0 + $1.hours } }
    private var sessionCount: Int { task.map { store.sessions(of: $0).count } ?? 0 }
    private var pullRequestCount: Int { task?.pullRequestList.count ?? 0 }
    /// With sessions and none yet, the tab is where one is added by its link.
    private var showsPullRequests: Bool { pullRequestCount > 0 || sessionCount > 0 }
    private var comments: [TicketDetail.Comment] {
        (detail?.comments ?? []).filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    @ViewBuilder
    private var content: some View {
            header
            Picker("View", selection: $tab) {
                Text("Description").tag(Tab.ticket)
                Text(detail == nil ? "Comments" : "Comments (\(comments.count))").tag(Tab.comments)
                // Only there when the task has sessions.
                if sessionCount > 0 { Text("Sessions (\(sessionCount))").tag(Tab.sessions) }
                // "PRs": a segmented control gives every tab the width of its longest label, and
                // six tabs of "Pull requests (2)" are wider than the sheet.
                if showsPullRequests {
                    Text(pullRequestCount > 0 ? "PRs (\(pullRequestCount))" : "PRs").tag(Tab.pullRequests)
                }
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
                        if let detail {
                            if explaining || !explanation.isEmpty || explainError != nil { explanationBox }
                            // No heading: the tab already says what this is.
                            let text = detail.description.trimmingCharacters(in: .whitespacesAndNewlines)
                            if detail.markdown && !text.isEmpty {
                                MarkdownView(text: text)
                            } else {
                                Text(text.isEmpty ? "No description." : text)
                                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    case .sessions:
                        // Saved in the app, so this shows even when the ticket cannot be fetched.
                        SessionsList(taskId: taskId)
                    case .pullRequests:
                        PullRequestsList(taskId: taskId)
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
                if Runners.anyAvailable {
                    Button { showSession = true } label: {
                        Label("Start session", systemImage: "terminal")
                    }
                    // Wait for the ticket so the agent gets its full text, not only the title.
                    .disabled(loading)
                    .help("Start an agent on this ticket in a new \(store.runner(for: project).label) worktree")
                }
                Button { editing = task } label: { Label("Edit", systemImage: "pencil") }
                    .help("Change the task's title, space, ticket or time")
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete…", systemImage: "trash") }
                    .help("Delete the task from the board. The ticket in the tracker is not touched.")
                Spacer()
                if isRedmine {
                    Button("Log time…") { showLog = true }
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .actionBar()
            // A solid bar: over the ticket's text the floating buttons were hard to read.
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            }
    }

    /// Keys of the details sheet, while no text is being typed: the tabs by arrow or number, and
    /// a letter for each button at the bottom.
    private func key(_ event: NSEvent, _: Bool) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty, !showEstimates else { return false }
        var tabs: [Tab] = [.ticket, .comments]
        if sessionCount > 0 { tabs.append(.sessions) }
        if showsPullRequests { tabs.append(.pullRequests) }
        tabs += [.time, .notes]
        let at = tabs.firstIndex(of: tab) ?? 0
        switch event.keyCode {
        // Tab walks the tabs and comes round again; with Shift, backwards.
        case 48:
            let step = event.modifierFlags.contains(.shift) ? -1 : 1
            tab = tabs[(at + step + tabs.count) % tabs.count]
            return true
        case 123: tab = tabs[max(at - 1, 0)]; return true
        case 124: tab = tabs[min(at + 1, tabs.count - 1)]; return true
        default: break
        }
        guard let letter = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if let number = Int(letter), number >= 1, number <= tabs.count {
            tab = tabs[number - 1]
            return true
        }
        switch letter {
        case "e": editing = task
        case "s":
            guard Runners.anyAvailable, !loading else { return false }
            showSession = true
        case "l":
            guard isRedmine else { return false }
            showLog = true
        case "x":
            guard !explaining, detail != nil else { return false }
            Task { await explain() }
        case "o":
            guard let link = task.flatMap({ URL(string: $0.url) }), link.scheme != nil else { return false }
            Browser.open(link, space: project)
        case "c":
            guard let link = task.flatMap({ URL(string: $0.url) }), link.scheme != nil else { return false }
            copyLink(link)
        case "t": store.toggleTimer(taskId)
        default: return false
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loading && detail == nil {
                // The first load: nothing else until everything can be shown at once.
                loadingView.padding(.top, -60).frame(maxHeight: .infinity)
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .actionBar()
            } else {
                content
            }
        }
        .frame(width: 720, height: 700)
        .background(KeyCatcher(field: nil, handler: key))
        // Links inside the ticket text and comments follow the space's browser too.
        .environment(\.openURL, OpenURLAction { url in
            Browser.open(url, space: project)
            return .handled
        })
        .task {
            explanation = task?.explanation ?? ""
            // The copy from last time shows at once; the tracker is asked again behind it.
            if let cached = TicketCache.load(taskId) {
                detail = cached.detail
                options = cached.options
            }
            await load()
        }
        .sheet(isPresented: $showLog, onDismiss: { Task { await load() } }) {
            LogTimeView(taskId: taskId).environment(store)
        }
        .sheet(item: $editing) { task in
            TaskEditor(task: task).environment(store)
        }
        .confirmationDialog("Delete “\(task.map { $0.title.isEmpty ? $0.displayRef : $0.title } ?? "")”?",
                            isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                store.delete(task: taskId)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its tracked time is deleted too. The ticket in \(project?.kind.label ?? "the tracker") stays as it is. This cannot be undone.")
        }
        // Deleted from the editor opened here: there is nothing left to show.
        // The last session was removed while its tab was open.
        .onChange(of: sessionCount) { _, count in
            if count == 0, tab == .sessions { tab = .ticket }
        }
        .onChange(of: showsPullRequests) { _, shown in
            if !shown, tab == .pullRequests { tab = .ticket }
        }
        .onChange(of: task == nil) { _, gone in
            if gone { dismiss() }
        }
        .sheet(isPresented: $showSession) {
            StartSessionView(taskId: taskId, detail: detail).environment(store)
        }
    }

    private var loadingView: some View {
        ProgressView("Loading from \(project?.kind.label ?? "tracker")…")
            .frame(maxWidth: .infinity).padding(.top, 60)
    }

    /// The user's own notes about the task. They are never posted to the tracker.
    private var notesSection: some View {
        section("My notes") {
            NotesEditor(notes: Binding(get: { task?.noteList ?? [] }, set: { store.setNotes(taskId, $0) }),
                        tracker: project?.kind.label, review: project?.review)
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
                let name = task?.displayRef ?? ""
                if let link = task.flatMap({ URL(string: $0.url) }), link.scheme != nil {
                    TicketLink(text: name, url: link, space: project)
                        .font(.callout.weight(.medium))
                        .help("Open in the browser. Right-click to copy the link.")
                        .contextMenu { linkMenu(link) }
                    Button { copyLink(link) } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Copy the link")
                } else {
                    Text(name).font(.callout).foregroundStyle(.secondary)
                }
                // The first load has its own spinner in the middle of the sheet.
                if changing || (loading && detail != nil) {
                    ProgressView().controlSize(.small)
                        .help(changing ? "Sending the change" : "Checking \(project?.kind.label ?? "the tracker") for changes")
                }
                Spacer()
            }
            Text(detail?.subject ?? task?.title ?? "").font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .contextMenu {
                    if let link = task.flatMap({ URL(string: $0.url) }), link.scheme != nil { linkMenu(link) }
                }
            if let detail { facts(detail) }
            if let changeError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(changeError, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    if let detour {
                        Button("Go through \(detour.via.name)") {
                            Task { await setStatus(detour.target, via: detour.via) }
                        }
                        .disabled(changing)
                    }
                }
            } else if let optionsError, detail != nil {
                Text("Status and assignee cannot be changed here: \(optionsError)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
    }

    @ViewBuilder
    private func linkMenu(_ link: URL) -> some View {
        Button("Open in Browser") { Browser.open(link, space: project) }
        Button("Copy Link") { copyLink(link) }
    }

    private func copyLink(_ link: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// Where the ticket stands, in one box under the title: status and assignee first, since those
    /// two can be changed, then what the tracker says about it.
    private func facts(_ detail: TicketDetail) -> some View {
        // "Due" has a row of its own below, where it can be set.
        let plain = detail.meta.filter { ($0.0 != "Assignee" || options == nil) && $0.0 != "Due" }
        // A long value (a parent ticket's title) gets a line of its own instead of a narrow column.
        let short = plain.filter { $0.1.count <= 30 }
        let long = plain.filter { $0.1.count > 30 }
        return VStack(alignment: .leading, spacing: 7) {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)], spacing: 7) {
                if let type = detail.kindLabel, !type.isEmpty {
                    fact("Type") { Text(type).textSelection(.enabled) }
                }
                if let status = detail.status {
                    fact("Status") {
                        if let options, !options.statuses.isEmpty {
                            statusMenu(status, options)
                        } else {
                            pill(status, editable: false)
                        }
                    }
                }
                if let options { fact("Assignee") { assigneeMenu(options) } }
                if let task { fact("Column") { columnMenu(task) } }
                if detail.tracksEstimate {
                    fact("Estimate") {
                        estimatePill(detail.estimatedHours, detail)
                            .popover(isPresented: $showEstimates, arrowEdge: .bottom) { estimateEditor(detail) }
                    }
                    // Shortened: the full name wrapped onto two lines in the label column.
                    if let dev = detail.devEstimate {
                        fact("Dev est.") { estimatePill(dev.hours, detail) }
                    }
                }
                if let task { fact("Due") { dueMenu(task) } }
                if let task { fact("Reminder") { reminderMenu(task) } }
                if let task, sessionCount > 0 { fact("Session") { sessionPills(task) } }
                ForEach(short, id: \.0) { item in
                    fact(item.0) { factValue(item, in: detail) }
                }
            }
            ForEach(long, id: \.0) { item in
                fact(item.0) { factValue(item, in: detail).lineLimit(2) }
            }
            // The logged-against-estimate bar keeps a line of its own: it needs the width.
            if detail.tracksEstimate, let estimate = detail.estimatedHours, estimate > 0 {
                fact("Logged") { estimateBar(detail, estimate: estimate) }
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    @ViewBuilder
    private func factValue(_ item: (String, String), in detail: TicketDetail) -> some View {
        if let link = detail.links[item.0] {
            TicketLink(text: item.1, url: link, space: project)
                .multilineTextAlignment(.leading)
                .contextMenu { linkMenu(link) }
        } else {
            Text(item.1).textSelection(.enabled)
        }
    }

    /// One badge per agent session, newest first; a click opens it in its runner. The full rows are in
    /// the Sessions tab.
    private func sessionPills(_ task: TaskItem) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(store.sessions(of: task).reversed().prefix(3))) { session in
                let link = store.status(of: session)?.badgeLink
                Button {
                    if let link { Browser.open(link, space: project) } else { Task { await Runners.reveal(session) } }
                } label: {
                    SessionBadge(status: store.status(of: session), count: 1)
                }
                .buttonStyle(.plain)
                .help(link != nil ? "\(session.name) — open the pull request" : "\(session.name) — open in \(Runners.label(of: session))")
                .contextMenu { Button("Open Session in \(Runners.label(of: session))") { Task { await Runners.reveal(session) } } }
            }
            if sessionCount > 3 {
                Button("+\(sessionCount - 3)") { tab = .sessions }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The board column the task is in. This moves the card only; the tracker is not told.
    private func columnMenu(_ task: TaskItem) -> some View {
        let current = store.columns.first { $0.id == task.status }
        return Menu {
            ForEach(store.columns) { column in
                Button { store.move(taskId, to: column.id) } label: {
                    if column.id == task.status { Label(column.displayName, systemImage: "checkmark") }
                    else { Text(column.displayName) }
                }
                .disabled(column.id == task.status)
            }
        } label: {
            pill(current?.displayName ?? "—", editable: true, icon: "rectangle.split.3x1")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Move the card to another column of the board")
    }

    private func fact<Value: View>(_ label: String, @ViewBuilder _ value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 68, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
    }

    private func pill(_ text: String, editable: Bool, icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.caption2) }
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
            // The arrow is what says the pill can be clicked.
            if editable { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .contentShape(Capsule())
    }

    private func statusMenu(_ status: String, _ options: TicketOptions) -> some View {
        Menu {
            // Jira lists only the steps from here, so the status the ticket has is not among them.
            if let current = options.currentStatus,
               !options.statuses.contains(where: { $0.name.caseInsensitiveCompare(current) == .orderedSame }) {
                Button {} label: { Label(current, systemImage: "checkmark") }.disabled(true)
                Divider()
            }
            ForEach(options.statuses) { choice in
                let isCurrent = choice.name.caseInsensitiveCompare(options.currentStatus ?? "") == .orderedSame
                Button { Task { await setStatus(choice) } } label: {
                    if isCurrent { Label(choice.name, systemImage: "checkmark") } else { Text(choice.name) }
                }
                .disabled(isCurrent)
            }
            if let source = options.statusSource {
                Divider()
                Text(source)
            }
        } label: {
            pill(status, editable: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(changing)
        .help("Change the status in \(project?.kind.label ?? "the tracker")")
    }

    private func assigneeMenu(_ options: TicketOptions) -> some View {
        let current = options.assignees.filter { options.currentAssignees.contains($0.id) }
        let label = current.isEmpty ? "Unassigned" : current.map(\.name).joined(separator: ", ")
        return Menu {
            if let me = options.me, !options.currentAssignees.contains(me) {
                Button("Assign to me") { Task { await pickAssignee(me, options) } }
            }
            if !options.currentAssignees.isEmpty {
                Button("Unassign") { Task { await setAssignees([]) } }
            }
            Divider()
            ForEach(options.assignees) { person in
                let on = options.currentAssignees.contains(person.id)
                Button { Task { await pickAssignee(person.id, options) } } label: {
                    if on { Label(person.name, systemImage: "checkmark") } else { Text(person.name) }
                }
                // With one assignee only, picking the same person again would change nothing.
                .disabled(on && !options.severalAssignees)
            }
            if let note = options.assigneesNote {
                Divider()
                Text(note)
            }
        } label: {
            pill(label, editable: true, icon: "person")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(changing)
        .help("Change who the ticket is assigned to in \(project?.kind.label ?? "the tracker")")
    }

    /// One person replaces the assignee; where several are allowed, picking one adds or removes it.
    private func pickAssignee(_ id: String, _ options: TicketOptions) async {
        guard options.severalAssignees else { return await setAssignees([id]) }
        var ids = options.currentAssignees
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        await setAssignees(ids.sorted())
    }

    private func setStatus(_ choice: TrackerChoice, via: TrackerChoice? = nil) async {
        guard let task, let project else { return }
        changing = true
        changeError = nil
        detour = nil
        do {
            try await TicketFetcher.setStatus(project: project, ref: task.ref, url: task.url, to: choice,
                                              via: via, among: options?.statuses ?? [])
        } catch let refused as StatusRefused {
            changeError = refused.message
            if let step = refused.via { detour = (choice, step) }
        } catch {
            changeError = "Could not change the status: \(error.localizedDescription)"
        }
        changing = false
        // Read again either way: the ticket shows what the tracker really holds now.
        await load(keepingChangeError: true)
    }

    private func setAssignees(_ ids: [String]) async {
        guard let task, let project else { return }
        changing = true
        changeError = nil
        detour = nil
        do {
            try await TicketFetcher.setAssignees(project: project, ref: task.ref, url: task.url, to: ids)
        } catch {
            changeError = "Could not change the assignee: \(error.localizedDescription)"
        }
        changing = false
        await load(keepingChangeError: true)
    }

    private func reminderMenu(_ task: TaskItem) -> some View {
        Menu {
            ReminderMenuItems(task: task) { pickingReminder = true }
        } label: {
            if let reminder = Reminders.shown(task) {
                let more = task.reminderList.count - 1
                pill(Reminders.label(reminder.at) + (more > 0 ? " +\(more)" : ""), editable: true, icon: "bell")
                    .foregroundStyle(reminder.firedAt == nil ? Color.primary : Color.orange)
            } else {
                pill("None", editable: true).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(task.reminderList.isEmpty ? "Get a notification about this task at a time you pick. It is kept in TaskDeck only." : Reminders.help(task))
        .popover(isPresented: $pickingReminder, arrowEdge: .bottom) { ReminderPicker(taskId: taskId).environment(store) }
    }

    private func dueMenu(_ task: TaskItem) -> some View {
        Menu {
            DueMenuItems(task: task) { pickingDue = true }
        } label: {
            if let due = task.due {
                pill(Due.label(due) + (task.dueDate == nil ? " · ticket" : ""), editable: true, icon: "calendar")
                    .foregroundStyle(Due.color(due) == .secondary ? Color.primary : Due.color(due))
            } else {
                pill("None", editable: true).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(task.due == nil ? "Set a due date. It is kept in TaskDeck only." : Due.help(task))
        .popover(isPresented: $pickingDue, arrowEdge: .bottom) { DuePicker(taskId: taskId).environment(store) }
    }

    /// A pill like Status and Assignee: the value, or "Not set" in orange, and a click to edit.
    private func estimatePill(_ hours: Double?, _ detail: TicketDetail) -> some View {
        let set = (hours ?? 0) > 0
        return Button { openEstimates(detail) } label: {
            pill(set ? String(format: "%g h", hours ?? 0) : "Not set", editable: true, icon: set ? nil : "hourglass")
                .foregroundStyle(set ? Color.primary : Color.orange)
        }
        .buttonStyle(.plain)
        .help("Set the estimate and dev estimate in Redmine")
    }

    private func openEstimates(_ detail: TicketDetail) {
        func text(_ hours: Double?) -> String { (hours ?? 0) > 0 ? String(format: "%g", hours ?? 0) : "" }
        estimateText = text(detail.estimatedHours)
        devEstimateText = text(detail.devEstimate?.hours)
        estimateError = nil
        estimateWhy = nil
        derivedField = nil
        showEstimates = true
    }

    /// The estimate is the dev estimate plus 40% for everything around the development.
    private static let estimateFactor = 1.4

    /// Fills the other field from the one just typed, when the other is empty or was filled by
    /// this rule before. Rounded to quarter hours.
    private func derive(from field: String, _ text: String) {
        // My own write to this field coming back as a change: not something the user typed.
        if derivedField == field, text == derivedText { return }
        if derivedField == field { derivedField = nil }
        let other = field == "dev" ? "estimate" : "dev"
        let otherText = other == "dev" ? devEstimateText : estimateText
        guard otherText.trimmingCharacters(in: .whitespaces).isEmpty || derivedField == other else { return }
        var result = ""
        if case .some(.some(let value)) = hours(text), value > 0 {
            let raw = field == "dev" ? value * Self.estimateFactor : value / Self.estimateFactor
            result = String(format: "%g", (raw * 4).rounded() / 4)
        }
        derivedField = result.isEmpty ? nil : other
        derivedText = result
        if other == "dev" { devEstimateText = result } else { estimateText = result }
    }

    private func suggestEstimates(_ detail: TicketDetail) async {
        guard let task, !suggestingEstimate else { return }
        suggestingEstimate = true
        estimateError = nil
        defer { suggestingEstimate = false }
        do {
            let idea = try await Claude.suggestEstimate(task: task, project: project, detail: detail,
                                                        model: store.claudeModel, instructions: store.aiInstructions)
            // Claude's two figures stand as given: neither is recomputed from the other.
            derivedField = nil
            if let estimate = idea.estimate { estimateText = String(format: "%g", estimate) }
            if detail.devEstimate != nil, let dev = idea.dev { devEstimateText = String(format: "%g", dev) }
            estimateWhy = idea.why.isEmpty ? nil : idea.why
        } catch {
            estimateError = "Could not get a suggestion: \(error.localizedDescription)"
        }
    }

    /// Hours typed with a comma or a dot. Empty clears the field; anything else that is not a
    /// number is refused rather than read as zero.
    private func hours(_ text: String) -> Double?? {
        let trimmed = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let value = Double(trimmed), value >= 0 else { return nil }
        return .some(value)
    }

    private func estimateEditor(_ detail: TicketDetail) -> some View {
        let valid = hours(estimateText) != nil && hours(devEstimateText) != nil
        return VStack(alignment: .leading, spacing: 10) {
            Text("Estimates in Redmine").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Estimate")
                    TextField("", text: $estimateText, prompt: Text("hours")).frame(width: 80)
                    Text("h").foregroundStyle(.secondary)
                }
                if detail.devEstimate != nil {
                    GridRow {
                        Text("Dev estimate")
                        TextField("", text: $devEstimateText, prompt: Text("hours")).frame(width: 80)
                        Text("h").foregroundStyle(.secondary)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(suggestingEstimate)
            .onChange(of: estimateText) { _, new in if detail.devEstimate != nil { derive(from: "estimate", new) } }
            .onChange(of: devEstimateText) { _, new in derive(from: "dev", new) }
            if detail.devEstimate != nil {
                Text(derivedField == nil ? "Fill one and the other is worked out: estimate = dev estimate + 40%."
                     : "\(derivedField == "dev" ? "Dev estimate" : "Estimate") worked out with the 40% rule. Type over it to change it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button { Task { await suggestEstimates(detail) } } label: {
                HStack(spacing: 4) {
                    ZStack {
                        Image(systemName: "sparkles").opacity(suggestingEstimate ? 0 : 1)
                        if suggestingEstimate { ProgressView().controlSize(.small) }
                    }
                    Text(suggestingEstimate ? "Reading the ticket…" : "Suggest from the ticket")
                }
            }
            .controlSize(.small)
            .disabled(suggestingEstimate || savingEstimates)
            .help("Ask Claude for an estimate from the description and comments. Nothing is saved until you press Save.")
            if let estimateWhy {
                Text(estimateWhy).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Proposed by Claude. Check it before you save.").font(.caption2).foregroundStyle(.tertiary)
            }
            if let estimateError {
                Text(estimateError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if savingEstimates { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { showEstimates = false }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await saveEstimates(detail) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid || savingEstimates || suggestingEstimate)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func saveEstimates(_ detail: TicketDetail) async {
        guard let task, let project, case .some(let estimate) = hours(estimateText),
              case .some(let devHours) = hours(devEstimateText) else { return }
        savingEstimates = true
        estimateError = nil
        defer { savingEstimates = false }
        var dev = detail.devEstimate
        dev?.hours = devHours
        do {
            try await TicketFetcher.setEstimates(project: project, ref: task.ref, estimate: estimate, dev: dev)
            showEstimates = false
        } catch {
            estimateError = error.localizedDescription
        }
        // Either way: after a refusal the sheet should show what Redmine really holds.
        await load(keepingChangeError: true)
    }

    /// Hours logged on the ticket against its estimate. Time tracked here and not logged yet is
    /// drawn as a paler stretch after the logged part: it is what the bar becomes once pushed.
    private func estimateBar(_ detail: TicketDetail, estimate: Double) -> some View {
        let logged = detail.totalSpentHours ?? 0
        let pending = Double(task?.unloggedSeconds ?? 0) / 3600
        let total = logged + (pending >= 1.0 / 60 ? pending : 0)
        let ratio = total / estimate
        let colour: Color = ratio > 1 ? Theme.accent : (ratio >= 0.8 ? .orange : .green)
        let rest = estimate - total
        return VStack(alignment: .leading, spacing: 4) {
            // Figures first: the row's label lines up with text, and a bar has no baseline.
            HStack(spacing: 4) {
                Text(String(format: "%.2f h logged of %.2f h", logged, estimate)).monospacedDigit()
                if total > logged {
                    Text(String(format: "· %.2f h to log", pending)).monospacedDigit().foregroundStyle(.orange)
                }
                Spacer(minLength: 6)
                Text(rest >= 0 ? String(format: "%.2f h left · %.0f%%", rest, ratio * 100)
                               : String(format: "%.2f h over · %.0f%%", -rest, ratio * 100))
                    .monospacedDigit()
                    .foregroundStyle(ratio > 1 ? Theme.accent : Color.secondary)
            }
            .font(.caption)
            .lineLimit(1)
            GeometryReader { geo in
                // Past the estimate the bar is full; the figures say by how much.
                let scale = geo.size.width / max(estimate, total)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(colour.opacity(0.45)).frame(width: max(0, total * scale))
                    Capsule().fill(colour).frame(width: max(0, logged * scale))
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Hours logged on the ticket by everyone, against its estimate. The paler part is time tracked here that is not logged yet.")
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

    private func load(keepingChangeError: Bool = false) async {
        guard let task, let project else {
            loading = false
            return
        }
        loading = true
        error = nil
        if !keepingChangeError {
            changeError = nil
            detour = nil
        }
        entriesError = nil
        defer { loading = false }
        // Asked for together and shown together, so the screen fills once instead of in steps.
        async let ticket = TicketFetcher.fetch(project: project, ref: task.ref, url: task.url)
        async let choices: Result<TicketOptions, Error>? = TicketFetcher.canEdit(project.kind) ? {
            do { return .success(try await TicketFetcher.options(project: project, ref: task.ref, url: task.url)) }
            catch { return .failure(error) }
        }() : nil
        async let hours: Result<[RedmineClient.SpentEntry], Error>? = {
            guard project.kind == .redmine, let id = Int(task.ref), let client = RedmineClient(project: project) else { return nil }
            do { return .success(try await client.myTimeEntries(issueId: id)) } catch { return .failure(error) }
        }()
        do {
            let fetched = try await ticket
            let (choices, hours) = await (choices, hours)
            detail = fetched
            switch choices {
            case .success(let found): options = found; optionsError = nil
            case .failure(let failure): options = nil; optionsError = failure.localizedDescription
            case nil: break
            }
            TicketCache.save(.init(detail: fetched, options: options), for: taskId)
            switch hours {
            case .success(let entries): myEntries = entries
            case .failure(let failure): entriesError = "Could not fetch your hours: \(failure.localizedDescription)"
            case nil: break
            }
            store.setRemote(taskId, from: fetched)
            if task.title.isEmpty, var updated = store.task(taskId) {
                updated.title = fetched.subject
                store.upsert(updated)
            }
        } catch {
            self.error = "Could not fetch the ticket: \(error.localizedDescription)"
            return
        }
    }
}
