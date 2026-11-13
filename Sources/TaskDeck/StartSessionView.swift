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
    @State private var repoId = ""
    @State private var agent = Orca.agents[0].id
    @State private var name = ""
    @State private var claudeHome = ""
    @State private var githubAccount = ""
    @State private var prompt = ""
    @State private var loading = true
    @State private var starting = false
    @State private var error: String?

    private var task: TaskItem? { store.task(taskId) }
    private var project: Project? { store.project(task?.projectId) }
    private var repo: Orca.Repo? { repos.first { $0.id == repoId } }
    private var homeTyped: String { claudeHome.trimmingCharacters(in: .whitespaces) }
    /// A home that was typed but is not a directory. An empty field is fine: Claude's default.
    private var homeMissing: Bool {
        agent == "claude" && !homeTyped.isEmpty && Orca.resolvedHome(homeTyped) == nil
    }
    private var canStart: Bool {
        !starting && repo != nil && !homeMissing
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
                    ForEach(repos) { Text($0.name).tag($0.id) }
                }
                .disabled(repos.isEmpty)
                Picker("Agent", selection: $agent) {
                    ForEach(Orca.agents, id: \.id) { Text($0.label).tag($0.id) }
                }
                if agent == "claude" {
                    TextField("Claude home", text: $claudeHome, prompt: Text("~/.claude (default)"))
                        .help("The directory Claude Code keeps its settings, MCP servers and logs in. Remembered for this project.")
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
                        Text("Creating the worktree…").foregroundStyle(.secondary)
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
            }
            if repos.isEmpty { error = "Orca has no repositories yet. Add one in Orca first." }
        } catch {
            self.error = "Could not read Orca's repositories: \(error.localizedDescription)"
        }
    }

    private func start() async {
        guard let task, let repo else { return }
        starting = true
        error = nil
        defer { starting = false }
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

    private var color: Color {
        switch status?.kind {
        case .working: return .blue
        // Orange is the app's "needs you" colour, as on the not-logged-time chip.
        case .yourTurn: return .orange
        case .prOpen: return .purple
        case .prMerged: return .green
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "terminal").font(.system(size: 9, weight: .bold))
            if let status {
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

/// The sessions of a task, newest first, each with a way back to it in Orca.
struct SessionsList: View {
    @Environment(AppStore.self) private var store
    let taskId: UUID

    private static let started: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        let sessions = (store.task(taskId)?.sessions ?? []).reversed()
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
                    Button("Open in Orca") { Task { await Orca.reveal(session) } }
                    Button { store.removeSession(session.id, from: taskId) } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from this list. The worktree stays in Orca.")
                }
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func agentLabel(_ id: String) -> String {
        Orca.agents.first { $0.id == id }?.label ?? id
    }
}
