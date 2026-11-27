import SwiftUI

/// The review in the overview: what needs the user across open tasks and their agent sessions,
/// most urgent first, with the way to each. With a space it shows that space's lines only; the
/// review itself always covers every space.
struct ReviewSection: View {
    @Environment(AppStore.self) private var store
    let spaceId: UUID?
    let onDetails: (TaskItem) -> Void

    @State private var showingPrompt = false
    @State private var showingLater = false

    var body: some View {
        let items = store.reviewItems(space: spaceId)
        let soon = items.filter { $0.urgency < 3 }
        let later = items.filter { $0.urgency >= 3 }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Review").font(.headline)
                Spacer()
                if store.reviewing { ProgressView().controlSize(.small) }
                Button(store.reviewing ? "Reviewing…" : "Review now") { Task { await store.runReview() } }
                    .controlSize(.small)
                    .disabled(store.reviewing)
                    .help("Goes over every open task and its agent sessions. Nothing is changed anywhere.")
            }
            if let review = store.review {
                if !review.summary.isEmpty, spaceId == nil {
                    // The same red box and sparkles as the ticket's "In simple words": both are
                    // Claude's words, and should be told apart from the app's own at a glance.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                        Text(review.summary).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Theme.accent.opacity(0.25)))
                }
                if items.isEmpty {
                    Text(spaceId == nil ? "Nothing needs you right now." : "Nothing in this space needs you right now.")
                        .foregroundStyle(.secondary)
                }
                ForEach(soon) { row($0) }
                if !later.isEmpty {
                    // Closed by default once there is something more urgent to read first.
                    if soon.isEmpty {
                        ForEach(later) { row($0) }
                    } else {
                        DisclosureGroup("When there is time · \(later.count)", isExpanded: $showingLater) {
                            VStack(alignment: .leading, spacing: 8) { ForEach(later) { row($0) } }
                                .padding(.top, 6)
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                footer(review)
            } else {
                Text("No review yet. It goes over every open task and its agent sessions and lists what needs you.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingPrompt) { SentText(text: store.lastReviewPrompt ?? "") }
        .task { store.reviewOnOverviewOpen() }
    }

    @ViewBuilder
    private func row(_ item: ReviewItem) -> some View {
        if let task = store.tasks.first(where: { $0.id == item.taskId }) {
            let space = store.project(task.projectId)
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(color(item.urgency)).frame(width: 8, height: 8).padding(.top, 5)
                    .help(item.urgency == 1 ? "Needs you now" : item.urgency == 2 ? "For today" : "When there is time")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Button { onDetails(task) } label: {
                            Text("\(task.displayRef) \(task.title)".trimmingCharacters(in: .whitespaces))
                                .fontWeight(.medium).lineLimit(1).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open the ticket")
                        if spaceId == nil, let space {
                            Text(space.name).font(.caption).foregroundStyle(space.color).lineLimit(1)
                        }
                    }
                    Text(item.text).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                action(item, task: task, space: space)
                if item.key != nil {
                    Button { store.dismissReview(item) } label: {
                        Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Nothing to do here: hide this line until something changes on the task.")
                    .accessibilityLabel("Dismiss")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// The one way on from a line. When what the line asks for is not there (no session left, no
    /// pull request known), the next best is offered rather than a button that does nothing.
    @ViewBuilder
    private func action(_ item: ReviewItem, task: TaskItem, space: Project?) -> some View {
        let session = store.headlineSession(of: task)
        let live = session.flatMap { store.status(of: $0) }.map { $0.kind != .gone } ?? false
        let pr = store.latestPullRequest(of: task)?.url ?? store.sessions(of: task).compactMap { store.status(of: $0)?.prURL }.last
        Group {
            switch item.action {
            case "open_pr":
                if let pr { Button("Open PR") { Browser.open(pr, space: space) } }
                else if let session, live { Button("Open in \(Runners.label(of: session))") { Task { await Runners.reveal(session) } } }
            case "open_session":
                if let session, live { Button("Open in \(Runners.label(of: session))") { Task { await Runners.reveal(session) } } }
                else if let pr { Button("Open PR") { Browser.open(pr, space: space) } }
            case "open_ticket":
                // The ticket view in the app, where its comments are; the browser is one click from there.
                Button("Open ticket") { onDetails(task) }
            default:
                EmptyView()
            }
        }
        .controlSize(.small)
    }

    private func color(_ urgency: Int) -> Color {
        urgency == 1 ? Theme.accent : urgency == 2 ? .orange : Color.secondary.opacity(0.6)
    }

    private func footer(_ review: Review) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let note = review.note {
                Text(note).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(facts(review)).fixedSize(horizontal: false, vertical: true)
                if store.lastReviewPrompt != nil {
                    Button("Show what was sent") { showingPrompt = true }
                        .buttonStyle(.link)
                        .help("The exact text of the last request to Claude.")
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    /// When it ran and what it took: "Reviewed 10:42. Claude read 31,204 tokens and wrote 1,180 …".
    private func facts(_ review: Review) -> String {
        var text = "Reviewed \(review.at.formatted(date: Calendar.current.isDateInToday(review.at) ? .omitted : .abbreviated, time: .shortened))."
        guard let asked = review.claudeAt else { return text }
        let home = review.home.isEmpty ? "the default Claude home" : review.home
        text += " Claude read \(review.inputTokens.formatted()) tokens and wrote \(review.outputTokens.formatted())"
        if asked != review.at, !Calendar.current.isDate(asked, equalTo: review.at, toGranularity: .minute) {
            text += " at \(asked.formatted(date: .omitted, time: .shortened))"
        }
        text += ", on the login of \(home)"
        if let model = review.model { text += " (\(model))" }
        text += "."
        // With a subscription login nothing is billed: the figure only shows the size.
        if let cost = review.cost { text += " At API prices that is \(cost.formatted(.currency(code: "USD").precision(.fractionLength(2...3))))." }
        return text
    }
}

/// The exact request of the last review, so what left this Mac can be read.
private struct SentText: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What was sent to Claude").font(.title3.weight(.semibold))
            Text("The instructions, then one block per task. Your notes on a task are part of it only where its space's review sends more than the status. Unsent ticket drafts never are.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(text).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }
}
