import SwiftUI

/// Starts an agent session in Orca for a task: a new checkout of the chosen repository with an agent
/// that receives the ticket as its first message.
struct StartSessionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskId: UUID
    /// The ticket as fetched from the tracker. Without it the prompt has only the title and link.
    let detail: TicketDetail?

    @State private var repos: [Orca.Repo] = []
    /// An Orca repository's id, or one of the two `Self.clone` / `Self.folder` choices below.
    @State private var repoId = ""
    /// What to clone, as typed: "owner/name" or a github.com address.
    @State private var cloneSource = ""
    @State private var folderName = ""
    /// Whether the new folder starts as a git repository. Remembered between sessions.
    @AppStorage("newFolderGit") private var folderGit = true
    /// Where the clone or the new folder goes, as typed. Suggested from where the repositories are.
    @State private var parent = ""
    /// What `start` is doing, shown beside the spinner.
    @State private var progress = ""
    @State private var agent = Orca.agents[0].id
    @State private var name = ""
    @State private var claudeHome = ""
    @State private var githubAccount = ""
    @State private var prompt = ""
    @State private var loading = true
    @State private var starting = false
    @State private var error: String?

    /// Picker choices that make a repository instead of naming one. Orca's ids are UUIDs.
    private static let clone = "+clone"
    private static let folder = "+folder"

    private var task: TaskItem? { store.task(taskId) }
    private var project: Project? { store.project(task?.projectId) }
    private var repo: Orca.Repo? { repos.first { $0.id == repoId } }
    /// The space's own repositories come first in the list; the rest stay reachable below them.
    private var spaceRepos: [Orca.Repo] {
        guard let project else { return [] }
        return repos.filter(project.owns)
    }
    private var otherRepos: [Orca.Repo] {
        guard let project else { return repos }
        return repos.filter { !project.owns($0) }
    }
    private var homeTyped: String { claudeHome.trimmingCharacters(in: .whitespaces) }
    /// A home that was typed but is not a directory. An empty field is fine: Claude's default.
    private var homeMissing: Bool {
        agent == "claude" && !homeTyped.isEmpty && Orca.resolvedHome(homeTyped) == nil
    }
    private var cloneSlug: String? { Orca.githubSlug(cloneSource) }
    /// The folder the clone or the new folder would be, or why it cannot be made. Nil while the
    /// name is still empty, so nothing is complained about before the user typed.
    private var destination: Result<String, Error>? {
        let name: String
        switch repoId {
        case Self.clone:
            guard let slug = cloneSlug else { return nil }
            name = String(slug.split(separator: "/").last ?? "")
        case Self.folder:
            name = folderName.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { return nil }
        default: return nil
        }
        return Result { try Orca.newDirectoryPath(named: name, in: parent) }
    }
    private var hasRepository: Bool {
        if repo != nil { return true }
        if case .success = destination { return true }
        return false
    }
    private var canStart: Bool {
        !starting && hasRepository && !homeMissing
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start session in Orca").font(.title3.weight(.semibold))
                if let task {
                    Text("\(task.displayRef) \(task.title)").foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(14)
            Divider()

            Form {
                Picker("Repository", selection: $repoId) {
                    if repoId.isEmpty { Text(loading ? "Loading…" : "Choose…").tag("") }
                    if spaceRepos.isEmpty {
                        ForEach(repos) { Text($0.name).tag($0.id) }
                    } else {
                        Section(project?.name ?? "This space") {
                            ForEach(spaceRepos) { Text($0.name).tag($0.id) }
                        }
                        Section("Other repositories") {
                            ForEach(otherRepos) { Text($0.name).tag($0.id) }
                        }
                    }
                    Divider()
                    Text("Clone from GitHub…").tag(Self.clone)
                    Text("New folder…").tag(Self.folder)
                }
                .disabled(loading)
                if repoId == Self.clone {
                    TextField("GitHub repository", text: $cloneSource, prompt: Text("owner/name or its address"))
                        .help("It is cloned with gh, as the GitHub account chosen below, and added to Orca.")
                    if !cloneSource.trimmingCharacters(in: .whitespaces).isEmpty, cloneSlug == nil {
                        Text("Type it as owner/name, or paste its github.com address.")
                            .font(.caption).foregroundStyle(.red)
                    }
                } else if repoId == Self.folder {
                    TextField("Folder name", text: $folderName)
                        .help("An empty folder is created and added to Orca.")
                    Toggle("Start a git repository in it", isOn: $folderGit)
                        .help("On: git init with one empty commit and no remote, so each session gets its own checkout and branch. Add a remote later with “git remote add”. Off: a plain folder, and sessions work in the folder itself.")
                }
                if repoId == Self.clone || repoId == Self.folder {
                    LabeledContent(repoId == Self.clone ? "Clone into" : "Create in") {
                        HStack(spacing: 6) {
                            TextField("Parent folder", text: $parent, prompt: Text("~/Workspace"))
                                .labelsHidden()
                            Button("Choose…") { chooseParent() }.tint(nil)
                        }
                    }
                    switch destination {
                    case .success(let path):
                        Text(path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    case .failure(let problem):
                        Text(problem.localizedDescription).font(.caption).foregroundStyle(.red)
                    case nil:
                        EmptyView()
                    }
                }
                Picker("Agent", selection: $agent) {
                    ForEach(Orca.agents, id: \.id) { Text($0.label).tag($0.id) }
                }
                if agent == "claude" {
                    TextField("Claude home", text: $claudeHome, prompt: Text("~/.claude (default)"))
                        .help("The directory Claude Code keeps its settings, MCP servers and logs in. Remembered for this space.")
                    if homeMissing {
                        Text("“\(homeTyped)” is not a directory on this Mac.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                GitHubAccountPicker(selection: $githubAccount)
                TextField("Worktree name", text: $name)
                    .help("Orca creates a new checkout with this name. Its branch name is based on it.")
                Section("First message to the agent") {
                    TextEditor(text: $prompt)
                        .font(.callout.monospaced())
                        .frame(minHeight: 220)
                    Text("Read it before you start: the ticket text was written by other people, and the agent can run commands in the repository. Your private notes are not included.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    if starting {
                        ProgressView().controlSize(.small)
                        Text(progress).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Start") { Task { await start() } }
                        .keyboardShortcut(.defaultAction)
                        .primaryGlass()
                        .disabled(!canStart)
                }
                .actionBar()
            }
        }
        .frame(width: 600, height: 640)
        .task { await prepare() }
    }

    private func prepare() async {
        if let task {
            name = Orca.worktreeName(ref: task.ref, title: detail?.subject ?? task.title)
            prompt = Orca.prompt(task: task, project: project, detail: detail)
        }
        claudeHome = project?.claudeHome ?? ""
        githubAccount = project?.githubAccount ?? ""
        defer { loading = false }
        do {
            repos = try await Orca.repos()
            if let saved = project?.orcaRepoId, repos.contains(where: { $0.id == saved }) {
                repoId = saved
            } else if spaceRepos.count == 1 {
                repoId = spaceRepos[0].id
            }
            // Beside the space's own repositories when it has any, else where most of them are.
            parent = Orca.usualParent(of: spaceRepos.isEmpty ? repos : spaceRepos)
                .map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~"
        } catch {
            self.error = "Could not read Orca's repositories: \(error.localizedDescription)"
        }
    }

    private func start() async {
        guard let task else { return }
        starting = true
        error = nil
        defer { starting = false }
        let repo: Orca.Repo
        do {
            if let chosen = self.repo {
                repo = chosen
            } else if repoId == Self.clone, let slug = cloneSlug {
                progress = "Cloning \(slug)…"
                repo = try await Orca.cloneRepository(slug: slug, into: parent, account: githubAccount)
                adopt(repo)
            } else if repoId == Self.folder {
                progress = "Creating the folder…"
                repo = try await Orca.createFolder(named: folderName, in: parent, git: folderGit)
                adopt(repo)
            } else {
                return
            }
        } catch {
            self.error = "The repository could not be added: \(error.localizedDescription)"
            return
        }
        progress = "Creating the worktree…"
        let comment = [task.displayRef, task.title].filter { !$0.isEmpty }.joined(separator: " ")
        do {
            let session = try await Orca.start(
                repo: repo, name: name.trimmingCharacters(in: .whitespaces), agent: agent,
                prompt: prompt, comment: comment, claudeHome: homeTyped, githubAccount: githubAccount)
            // A Codex session says nothing about the project's Claude home, so it is left as it was.
            store.addSession(session, to: taskId, repoId: repo.id, claudeHome: agent == "claude" ? homeTyped : nil,
                             githubAccount: githubAccount)
            dismiss()
        } catch {
            self.error = "Orca could not start the session: \(error.localizedDescription)"
        }
    }
}

extension StartSessionView {
    /// Selects a repository that was just made, so a second try after a failed start uses it
    /// instead of cloning or creating it again.
    private func adopt(_ repo: Orca.Repo) {
        if !repos.contains(where: { $0.id == repo.id }) {
            repos = (repos + [repo]).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        repoId = repo.id
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if let current = Orca.resolvedDirectory(parent) { panel.directoryURL = URL(fileURLWithPath: current) }
        if panel.runModal() == .OK, let url = panel.url {
            parent = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

/// Ticks the Orca repositories that belong to a space.
struct SpaceRepositories: View {
    @Binding var selection: [String]
    /// The organisation whose repositories all belong to the space; empty for none.
    @Binding var organisation: String
    @State private var repos: [Orca.Repo] = []
    @State private var search = ""
    /// The GitHub organisation shown; empty for all of them.
    @State private var owner = ""
    @State private var failure: String?
    @State private var loaded = false

    private var owners: [String] {
        Set(repos.compactMap(\.owner)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    private var shown: [Orca.Repo] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return repos.filter { repo in
            (owner.isEmpty || repo.owner == owner)
                && (query.isEmpty || repo.name.localizedCaseInsensitiveContains(query))
        }
    }
    private var allShownTicked: Bool { shown.allSatisfy { selection.contains($0.id) } }
    /// Saved ids that Orca no longer lists. Shown so they can be removed instead of lingering unseen.
    private var missing: [String] {
        loaded && failure == nil ? selection.filter { id in !repos.contains { $0.id == id } } : []
    }

    private func included(_ repo: Orca.Repo) -> Bool {
        !organisation.isEmpty && repo.owner?.caseInsensitiveCompare(organisation) == .orderedSame
    }

    var body: some View {
        if owners.count > 0 || !organisation.isEmpty {
            Picker("GitHub organisation", selection: $organisation) {
                Text("None").tag("")
                ForEach(owners.contains(organisation) || organisation.isEmpty ? owners : owners + [organisation],
                        id: \.self) { Text($0).tag($0) }
            }
            .help("Every Orca repository of this organisation belongs to the space, including ones added later.")
        }
        LabeledContent("Repositories") {
            VStack(alignment: .leading, spacing: 6) {
                if let failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                } else if !loaded {
                    ProgressView().controlSize(.small)
                } else if repos.isEmpty {
                    Text("Orca has no repositories yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    if owners.count > 1 {
                        HStack(spacing: 6) {
                            Picker("Organisation", selection: $owner) {
                                Text("All organisations").tag("")
                                ForEach(owners, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            // Only with an organisation chosen: ticking every repository Orca has is never wanted.
                            if !owner.isEmpty, !shown.isEmpty {
                                Button(allShownTicked ? "Untick all" : "Tick all") { tickShown(!allShownTicked) }
                                    .controlSize(.small)
                            }
                        }
                    }
                    if repos.count > 8 {
                        TextField("Filter", text: $search, prompt: Text("Filter by name"))
                            .textFieldStyle(.roundedBorder).labelsHidden()
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(shown) { repo in
                                if included(repo) {
                                    Toggle(repo.name, isOn: .constant(true)).toggleStyle(.checkbox).disabled(true)
                                        .help("Included by the space's organisation.")
                                } else {
                                    Toggle(repo.name, isOn: binding(repo.id)).toggleStyle(.checkbox)
                                }
                            }
                            ForEach(missing, id: \.self) { id in
                                Toggle("No longer in Orca", isOn: binding(id)).toggleStyle(.checkbox)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 110)
                }
            }
            .frame(maxWidth: 260, alignment: .leading)
        }
        .task {
            do { repos = try await Orca.repos() } catch { failure = error.localizedDescription }
            loaded = true
        }
    }

    private func tickShown(_ on: Bool) {
        let ids = shown.map(\.id)
        selection.removeAll { ids.contains($0) }
        if on { selection += ids }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { selection.contains(id) },
                set: { on in
                    if on { if !selection.contains(id) { selection.append(id) } }
                    else { selection.removeAll { $0 == id } }
                })
    }
}

/// Chooses which signed-in `gh` account a project's agent sessions use.
struct GitHubAccountPicker: View {
    @Binding var selection: String
    @State private var accounts: [String] = []

    var body: some View {
        Picker("GitHub account", selection: $selection) {
            Text("gh's active account").tag("")
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .help("The account the agent's gh commands run as. Accounts come from “gh auth login”.")
        .task { accounts = await Orca.githubAccounts() }
    }

    /// The saved account stays selectable even when gh no longer lists it, so it is not silently dropped.
    private var options: [String] {
        selection.isEmpty || accounts.contains(selection) ? accounts : accounts + [selection]
    }
}

/// A small chip for a session: a terminal icon and, when Orca answered, what the session is doing.
struct SessionBadge: View {
    let status: Orca.Status?
    /// How many sessions the task has; shown when there is no status to show instead.
    let count: Int
    /// Icon only, in the status colour, for a card with no room for the word.
    var compact = false
    /// Beside a `PullRequestBadge`: about the agent only, since the pull request has its own badge.
    var agentOnly = false

    private var color: Color {
        if agentOnly, status?.isAboutPullRequest == true { return .secondary }
        switch status?.kind {
        case .working: return .blue
        // Orange is the app's "needs you" colour, as on the not-logged-time chip.
        case .yourTurn: return .orange
        // As on GitHub: open is green, merged purple.
        case .prOpen: return .green
        case .prMerged: return .purple
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "terminal").font(.system(size: 9, weight: .bold))
            if compact || (agentOnly && status?.isAboutPullRequest == true) {
                // With a pull request the agent is idle: the icon is enough to say "the session".
                EmptyView()
            } else if let status {
                Text(status.label).font(.caption.weight(.medium))
            } else if count > 1 {
                Text("\(count)").font(.caption.weight(.medium)).monospacedDigit()
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
    }
}

/// A chip for a pull request, apart from the session's own badge.
struct PullRequestBadge: View {
    private let label: String
    private let color: Color
    var compact = false

    /// A session's pull request, as Orca's status has it.
    init(status: Orca.Status, compact: Bool = false) {
        switch status.kind {
        case .prMerged: color = .purple
        case .prClosed: color = .secondary
        default: color = status.prDraft ? .secondary : .green
        }
        // While the agent works or waits the status is about the agent, so the number is all
        // that is known about the pull request.
        label = status.isAboutPullRequest ? status.label : status.prNumber.map { "PR #\($0)" } ?? "PR"
        self.compact = compact
    }

    /// One of a task's saved pull requests, as GitHub last had it. The colour says where it
    /// stands: purple merged, grey closed or draft, and for an open one red when its checks fail
    /// or it conflicts, orange when a review or comment waits for an answer, green when its
    /// checks pass or it is approved, blue while checks run or nothing is known yet.
    init(_ pullRequest: TaskPullRequest, compact: Bool = false) {
        switch pullRequest.state {
        case "merged": color = .purple
        case "closed": color = .secondary
        default:
            if pullRequest.checks == "failing" || pullRequest.conflict == true { color = .red }
            else if (pullRequest.waiting ?? 0) > 0 { color = .orange }
            else if pullRequest.draft == true { color = .secondary }
            else if pullRequest.checks == "pending" || pullRequest.checkedAt == nil { color = .blue }
            else if pullRequest.checks == "passing" || pullRequest.approved == true { color = .green }
            else { color = .blue }
        }
        label = pullRequest.label
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 9, weight: .bold))
            if !compact { Text(label).font(.caption.weight(.medium)) }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
    }
}

/// The sessions of a task, newest first, each with a way back to it in Orca.
struct SessionsList: View {
    @Environment(AppStore.self) private var store
    let taskId: UUID
    @State private var removing: [TaskWorktree] = []

    private static let started: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        let sessions = (store.task(taskId).map(store.sessions(of:)) ?? []).reversed()
        VStack(spacing: 6) {
            ForEach(Array(sessions)) { session in
                let status = store.status(of: session)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(session.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            SessionBadge(status: status, count: 1)
                        }
                        Text("\(agentLabel(session.agent))\(session.claudeHome.map { " (\($0))" } ?? "")\(session.githubAccount.map { " · gh \($0)" } ?? "") · \(session.repoName) · \(Self.started.string(from: session.startedAt))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        // What the agent last said, so the user can decide without opening Orca.
                        if let status, status.kind != .working, let message = status.lastMessage, !message.isEmpty {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(3).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if let status, status.kind == .working, let tool = status.tool {
                            Text("Running \(tool)…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let pr = status?.prURL {
                        Button("Open PR") { Browser.open(pr, space: store.project(store.task(taskId)?.projectId)) }
                    }
                    Button("Open in Orca") { Task { await Orca.reveal(session) } }
                    if let id = session.worktreeId, store.removingWorktrees.contains(id) {
                        ProgressView().controlSize(.small).help("Removing the worktree in Orca…")
                    } else if let task = store.task(taskId), store.removableSessions(of: task).contains(session) {
                        Button { removing = [TaskWorktree(taskId: taskId, session: session)] } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove the worktree in Orca: its checkout is deleted.")
                    }
                    // A worktree matched by its name would only be found again on the next refresh.
                    if !session.agent.isEmpty {
                        Button { store.removeSession(session.id, from: taskId) } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from this list. The worktree stays in Orca.")
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .removingWorktrees($removing)
    }

    private func agentLabel(_ id: String) -> String {
        id.isEmpty ? "Created in Orca" : Orca.agents.first { $0.id == id }?.label ?? id
    }
}
