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
    @State private var prompt = ""
    @State private var loading = true
    @State private var starting = false
    @State private var error: String?

    private var task: TaskItem? { store.task(taskId) }
    private var project: Project? { store.project(task?.projectId) }
    private var repo: Orca.Repo? { repos.first { $0.id == repoId } }
    private var canStart: Bool {
        !starting && repo != nil
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
                prompt: prompt, comment: comment)
            store.addSession(session, to: taskId, repoId: repo.id)
            dismiss()
        } catch {
            self.error = "Orca could not start the session: \(error.localizedDescription)"
        }
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
                HStack(spacing: 10) {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text("\(agentLabel(session.agent)) · \(session.repoName) · \(Self.started.string(from: session.startedAt))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
