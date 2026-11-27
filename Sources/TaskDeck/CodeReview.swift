import SwiftUI

/// A code review of somebody else's pull request: not a ticket of the user's, so it starts from a
/// link instead of a task, and its first message is a review command rather than the ticket.
enum CodeReview {
    struct PullRequest: Hashable {
        /// "owner/name" on github.com.
        let slug: String
        let number: Int
        var repoName: String { String(slug.split(separator: "/").last ?? "") }
        var url: String { "https://github.com/\(slug)/pull/\(number)" }
        var ref: String { "\(repoName)#\(number)" }
    }

    /// The pull request a pasted address names: "https://github.com/owner/name/pull/12", with or
    /// without what follows the number ("/files", "#discussion…"). Nil for anything else.
    static func pullRequest(_ typed: String) -> PullRequest? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let parts = URLComponents(string: text), let host = parts.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        guard path.count >= 4, path[2] == "pull", let number = Int(path[3]), number > 0,
              let slug = GitHub.slug("\(path[0])/\(path[1])") else { return nil }
        return PullRequest(slug: slug, number: number)
    }

    static let standardCommand = "/code-review high {number}"

    /// Used when neither the space nor Settings has its own.
    static let standardPrompt = """
        \(standardCommand)

        This is a review of somebody else's pull request: {url}
        Report what you find to me. Do not change code, push, or comment on the pull request.
        """

    static let placeholders: [(name: String, meaning: String)] = [
        ("{number}", "the pull request's number"),
        ("{url}", "its link"),
        ("{title}", "its title"),
        ("{repo}", "the repository, as owner/name"),
    ]

    static var placeholderHelp: String {
        placeholders.map { "\($0.name) is \($0.meaning)" }.joined(separator: "; ") + "."
    }

    /// The space's own message, else the one from Settings, else the standard one.
    static func template(space: Project?, app: String) -> String {
        for candidate in [space?.codeReviewPrompt ?? "", app] {
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return standardPrompt
    }

    /// Replaces the placeholders in one pass, so a title that happens to contain "{url}" stays as
    /// it is.
    static func prompt(template: String, pullRequest: PullRequest, title: String) -> String {
        let values = ["{number}": String(pullRequest.number), "{url}": pullRequest.url,
                      "{title}": title, "{repo}": pullRequest.slug]
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            rest = rest[open...]
            if let match = values.first(where: { rest.hasPrefix($0.key) }) {
                result += match.value
                rest = rest.dropFirst(match.key.count)
            } else {
                result += "{"
                rest = rest.dropFirst()
            }
        }
        return result + rest
    }
}

/// Starts a code review session in Orca from a pull request's link.
struct CodeReviewView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// The space the board shows, used when no space owns the repository.
    let space: UUID?
    /// The link pasted or dropped on the board; nil to look at the clipboard.
    var initialLink: String?

    init(space: UUID?, link: String? = nil) {
        self.space = space
        self.initialLink = link
    }

    @State private var link = ""
    @State private var repos: [SessionRepo] = []
    @State private var spaceId: UUID?
    @State private var title = ""
    /// Where the repository is cloned when the runner does not have it, as typed.
    @State private var parent = "~"
    /// The `SessionRunner.id` of the chosen space, or the app's default without one.
    @State private var runnerId = ""
    @State private var agent = ""
    @State private var name = ""
    @State private var claudeHome = ""
    @State private var githubAccount = ""
    @State private var prompt = ""
    /// The message as last filled in from the template. While the field still equals it the user
    /// has not edited it, and it may be filled in again.
    @State private var filled = ""
    @State private var checkOut = true
    @State private var addCard = true
    @State private var loading = true
    @State private var starting = false
    @State private var progress = ""
    @State private var error: String?

    private var pullRequest: CodeReview.PullRequest? { CodeReview.pullRequest(link) }
    private var project: Project? { store.project(spaceId) }
    private var runner: any SessionRunner { Runners.resolve(runnerId.isEmpty ? nil : runnerId) }
    private var agentKind: AgentKind { AgentKind.find(agent) ?? runner.agents.first ?? .claude }
    private var repo: SessionRepo? {
        guard let pullRequest else { return nil }
        return repos.first { $0.slug?.caseInsensitiveCompare(pullRequest.slug) == .orderedSame }
    }
    private var homeTyped: String { claudeHome.trimmingCharacters(in: .whitespaces) }
    private var homeMissing: Bool {
        agentKind.homeVariable != nil && !homeTyped.isEmpty && Sessions.resolvedHome(homeTyped) == nil
    }
    /// Where the clone would go, or why it cannot. Nil when nothing has to be cloned.
    private var destination: Result<String, Error>? {
        guard !loading, let pullRequest, repo == nil else { return nil }
        return Result { try Sessions.newDirectoryPath(named: pullRequest.repoName, in: parent) }
    }
    private var canStart: Bool {
        guard !starting, !loading, pullRequest != nil, !homeMissing else { return false }
        if case .failure = destination { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review a pull request").font(.title3.weight(.semibold))
                Text(title.isEmpty ? "An agent session that reviews somebody else's pull request." : title)
                    .foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(14)
            Divider()

            Form {
                TextField("Pull request", text: $link, prompt: Text("https://github.com/owner/name/pull/123"))
                if !link.trimmingCharacters(in: .whitespaces).isEmpty, pullRequest == nil {
                    Text("Paste the pull request's github.com address.").font(.caption).foregroundStyle(.red)
                }
                if let pullRequest {
                    if let repo {
                        LabeledContent("Repository", value: repo.name)
                    } else if !loading {
                        LabeledContent("Clone into") {
                            HStack(spacing: 6) {
                                TextField("Parent folder", text: $parent, prompt: Text("~/Workspace")).labelsHidden()
                                Button("Choose…") { chooseParent() }.tint(nil)
                            }
                        }
                        switch destination {
                        case .success(let path):
                            Text("\(runner.label) does not have \(pullRequest.slug) yet. It is cloned to \(path) and added to \(runner.label).")
                                .font(.caption).foregroundStyle(.secondary)
                        case .failure(let problem):
                            Text(problem.localizedDescription).font(.caption).foregroundStyle(.red)
                        case nil:
                            EmptyView()
                        }
                    }
                    Toggle("Start from the pull request's code", isOn: $checkOut)
                        .help("On: the pull request is fetched and the new checkout starts from it, so the agent reads the code under review. Off: the checkout starts from the repository's default branch.")
                }
                Picker("Space", selection: $spaceId) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.projects) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .help("Its Claude home, GitHub account and code review message are used, and the card goes on its board.")
                Picker("Agent", selection: $agent) {
                    if agent.isEmpty { Text("Loading…").tag("") }
                    ForEach(runner.agents, id: \.id) { Text($0.label).tag($0.id) }
                }
                if agentKind.homeVariable != nil {
                    TextField("Claude home", text: $claudeHome, prompt: Text("~/.claude (default)"))
                    if homeMissing {
                        Text("“\(homeTyped)” is not a directory on this Mac.").font(.caption).foregroundStyle(.red)
                    }
                }
                GitHubAccountPicker(selection: $githubAccount)
                TextField("Worktree name", text: $name)
                Toggle("Add a card to the board", isOn: $addCard)
                    .help("On: a card for the review goes in In progress, with the session on it, so its status, notifications and time tracking work as for a task. Off: the session is only started in \(runner.label).")
                Section("First message to the agent") {
                    TextEditor(text: $prompt)
                        .font(.callout.monospaced())
                        .frame(minHeight: 150)
                    Text("It comes from the space's code review message, or the one in Settings, Agents. The pull request itself was written by somebody else, and the agent can run commands in the checkout.")
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
        .onChange(of: pullRequest) { _, _ in
            // The old pull request's title must not be sent as the new one's.
            title = ""
            adoptPullRequest()
        }
        .onChange(of: spaceId) { _, _ in adoptSpace() }
        // The title is asked again when the account changes: a private repository answers only
        // to the account that can see it.
        .task(id: "\(pullRequest?.url ?? "")|\(githubAccount)") { await fetchTitle() }
    }

    private func prepare() async {
        spaceId = space
        adoptSpace()
        // A link copied just before opening the sheet is the usual way here.
        if let copied = initialLink ?? NSPasteboard.general.string(forType: .string),
           CodeReview.pullRequest(copied) != nil {
            link = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        await loadRepos()
        adoptPullRequest()
    }

    private func loadRepos() async {
        loading = true
        defer { loading = false }
        let runner = runner
        do {
            repos = try await runner.repos()
            parent = Sessions.usualParent(of: repos).map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~"
            error = nil
        } catch {
            repos = []
            self.error = "Could not read \(runner.label)'s repositories: \(error.localizedDescription)"
        }
    }

    /// A new link: its name, and the space that owns its repository when one does.
    private func adoptPullRequest() {
        guard let pullRequest else { return refill() }
        name = Sessions.worktreeName(ref: "review-\(pullRequest.repoName)-\(pullRequest.number)", title: "")
        if let repo, let owner = store.projects.first(where: { $0.owns(repo) }) { spaceId = owner.id }
        refill()
    }

    private func adoptSpace() {
        claudeHome = project?.claudeHome ?? ""
        githubAccount = project?.githubAccount ?? ""
        let chosen = store.runner(for: project)
        agent = store.agent(for: project, runner: chosen).id
        if chosen.id != runnerId {
            // Another runner has other repositories; the first look happens in `prepare`.
            let first = runnerId.isEmpty
            runnerId = chosen.id
            if !first { Task { await loadRepos() } }
        }
        refill()
    }

    /// Fills the message from the template, unless the user has edited it.
    private func refill() {
        guard prompt == filled else { return }
        if let pullRequest {
            prompt = CodeReview.prompt(template: CodeReview.template(space: project, app: store.codeReviewPrompt),
                                       pullRequest: pullRequest, title: title)
        } else {
            prompt = ""
        }
        filled = prompt
    }

    private func fetchTitle() async {
        guard let pullRequest, let url = URL(string: pullRequest.url) else { return }
        // Not on every keystroke of a typed link.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled,
              let detail = await GitHub.pullRequestDetail(url, account: githubAccount), !Task.isCancelled else { return }
        title = detail.title
        refill()
    }

    private func start() async {
        guard let pullRequest else { return }
        starting = true
        error = nil
        defer { starting = false }
        let runner = runner
        let repo: SessionRepo
        do {
            if let known = self.repo {
                repo = known
            } else {
                progress = "Cloning \(pullRequest.slug)…"
                repo = try await Sessions.cloneRepository(slug: pullRequest.slug, into: parent, account: githubAccount, runner: runner)
                // Listed from now on, so a second try after a failed start does not clone again.
                repos.append(repo)
            }
        } catch {
            self.error = "The repository could not be added: \(error.localizedDescription)"
            return
        }
        var base: String?
        if checkOut {
            progress = "Fetching the pull request…"
            do {
                base = try await GitHub.fetchPullRequest(pullRequest.number, in: repo.path, account: githubAccount)
            } catch {
                self.error = "The pull request could not be fetched: \(error.localizedDescription) Turn off “Start from the pull request's code” to review it from the default branch."
                return
            }
        }
        progress = "Creating the worktree…"
        let heading = title.isEmpty ? pullRequest.ref : title
        do {
            let session = try await runner.start(SessionLaunch(
                repo: repo, name: name.trimmingCharacters(in: .whitespaces), agent: agentKind, prompt: prompt,
                comment: "Review \(pullRequest.ref) \(title)".trimmingCharacters(in: .whitespaces),
                home: homeTyped, githubAccount: githubAccount, baseBranch: base))
            if addCard {
                // A Jira space would ask Jira about any reference every refresh, so there the
                // pull request is named in the title instead.
                let asRef = project?.kind != .jira
                var task = TaskItem(projectId: spaceId, ref: asRef ? pullRequest.ref : "",
                                    title: asRef ? "Review: \(heading)" : "Review \(pullRequest.ref): \(title)",
                                    url: pullRequest.url,
                                    status: store.columns.first { $0.role == .inProgress }?.id ?? store.defaultColumnId)
                task.title = task.title.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                store.upsert(task)
                store.addSession(session, to: task.id, repoId: repo.id, githubAccount: githubAccount, remember: false)
            } else {
                // Nothing in the app leads to this session, so the runner is shown on it.
                await Runners.reveal(session)
            }
            dismiss()
        } catch {
            self.error = "\(runner.label) could not start the session: \(error.localizedDescription)"
        }
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if let current = Sessions.resolvedDirectory(parent) { panel.directoryURL = URL(fileURLWithPath: current) }
        if panel.runModal() == .OK, let url = panel.url {
            parent = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}
