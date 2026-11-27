import SwiftUI

/// Every pull request of a task, newest first, with what GitHub last said about each, and a
/// field to add one by its link.
struct PullRequestsList: View {
    @Environment(AppStore.self) private var store
    let taskId: UUID
    @State private var link = ""
    @State private var refreshing = false

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    private var task: TaskItem? { store.task(taskId) }
    private var space: Project? { store.project(task?.projectId) }

    var body: some View {
        let list = task?.pullRequestList ?? []
        VStack(alignment: .leading, spacing: 6) {
            ForEach(list) { pr in row(pr) }
            if list.isEmpty {
                Text("No pull request yet. One opened from this task's agent sessions is added here by itself.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                // Verbatim: as a localised key the address would be drawn as a link.
                TextField("", text: $link, prompt: Text(verbatim: "Paste a pull request's link to add it"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(CodeReview.pullRequest(link) == nil)
                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Ask GitHub again now. Open pull requests are read every five minutes anyway.")
                }
            }
            .padding(.top, 4)
            if !link.trimmingCharacters(in: .whitespaces).isEmpty, CodeReview.pullRequest(link) == nil {
                Text("That is not a GitHub pull request's address.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ pr: TaskPullRequest) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    PullRequestBadge(pr)
                    Text(pr.title ?? "\(pr.slug)#\(pr.number)").font(.callout.weight(.medium)).lineLimit(1)
                }
                Text(facts(pr)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if pr.checkedAt != nil, pr.isOpen {
                    HStack(spacing: 6) {
                        if let review = review(pr) { chip(review.text, review.color) }
                        if let checks = pr.checks { chip("Checks \(checks)", checks == "failing" ? .red : checks == "passing" ? .green : .secondary) }
                        if pr.conflict == true { chip("Merge conflict", .red) }
                    }
                }
            }
            Spacer(minLength: 8)
            if let page = pr.url {
                Button("Open") { Browser.open(page, space: space) }
            }
            Button { store.forgetPullRequest(pr.id, from: taskId) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Take it off this task's list. Nothing changes on GitHub.")
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Repository, dates, which session, and how old the answer is.
    private func facts(_ pr: TaskPullRequest) -> String {
        var parts = [pr.slug]
        if let merged = pr.mergedAt {
            parts.append("merged \(Self.day.string(from: merged))")
        } else if pr.state == "closed", let closed = pr.closedAt {
            parts.append("closed \(Self.day.string(from: closed))")
        } else if let opened = pr.createdAt {
            parts.append("opened \(Self.day.string(from: opened))")
        }
        if let task, let session = store.sessions(of: task).first(where: { $0.worktreeId != nil && $0.worktreeId == pr.worktreeId }) {
            parts.append("from \(session.name)")
        }
        if let checked = pr.checkedAt {
            // Under a minute the relative style says "in 0 sec".
            if pr.isOpen {
                parts.append(Date().timeIntervalSince(checked) < 60 ? "checked just now"
                             : "checked \(checked.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
            }
        } else {
            parts.append("GitHub has not answered yet")
        }
        return parts.joined(separator: " · ")
    }

    private func review(_ pr: TaskPullRequest) -> (text: String, color: Color)? {
        let waiting = pr.waiting ?? 0
        if pr.changesRequested == true {
            return (waiting > 0 ? "Changes requested" : "Changes requested, answered", waiting > 0 ? .orange : .secondary)
        }
        if waiting > 0 { return (waiting == 1 ? "1 comment to answer" : "\(waiting) comments to answer", .orange) }
        if pr.approved == true { return ("Approved", .green) }
        return nil
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func add() {
        if store.addPullRequest(link: link, to: taskId) { link = "" }
    }

    private func refresh() {
        refreshing = true
        Task {
            await store.refreshPullRequestStatuses(force: true)
            refreshing = false
        }
    }
}
