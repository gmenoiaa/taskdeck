import SwiftUI

/// A runner's worktree and the task it belongs to.
struct TaskWorktree: Hashable, Identifiable {
    let taskId: UUID
    let session: AgentSession
    var id: String { session.worktreeId ?? session.id.uuidString }
}

/// Asks before removing worktrees in their runner, removes them, and says which ones the runner refused.
/// Those can then be removed anyway, changes and all. Set `pending` to start; it is emptied
/// once the user answers.
private struct RemoveWorktrees: ViewModifier {
    @Environment(AppStore.self) private var store
    @Binding var pending: [TaskWorktree]
    @State private var failures: [(item: TaskWorktree, reason: String)] = []

    private var title: String {
        pending.count == 1 ? "Remove the worktree “\(pending[0].session.name)”?" : "Remove \(pending.count) worktrees?"
    }

    /// The runner's name when every item is in the same one.
    private static func runner(of items: [TaskWorktree]) -> String {
        let names = Set(items.map { Runners.label(of: $0.session) })
        return names.count == 1 ? names.first ?? "its runner" : "its runner"
    }

    private var message: String {
        let runner = Self.runner(of: pending)
        var lines: [String] = []
        if pending.count > 1 {
            lines.append(pending.prefix(6).map { "\($0.session.repoName) · \($0.session.name)" }.joined(separator: "\n")
                         + (pending.count > 6 ? "\n…and \(pending.count - 6) more" : ""))
        }
        lines.append("The checkout is deleted and the worktree leaves \(runner). One with uncommitted changes is kept, "
                     + "and so is any branch \(runner) cannot tell is merged.")
        return lines.joined(separator: "\n\n")
    }

    private var failureMessage: String {
        failures.map { "\($0.item.session.name): \($0.reason)" }.joined(separator: "\n\n")
            + "\n\nRemoving anyway deletes the uncommitted changes with the checkout. "
            + "Committed work stays on its branch, which \(Self.runner(of: failures.map(\.item))) keeps unless it is merged."
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(title, isPresented: Binding(get: { !pending.isEmpty }, set: { if !$0 { pending = [] } }),
                                titleVisibility: .visible) {
                Button(pending.count == 1 ? "Remove Worktree" : "Remove \(pending.count) Worktrees", role: .destructive) {
                    let items = pending
                    pending = []
                    Task { failures = await store.removeWorktrees(items) }
                }
                Button("Cancel", role: .cancel) { pending = [] }
            } message: {
                Text(message)
            }
            .alert(failures.count == 1 ? "A worktree was not removed" : "\(failures.count) worktrees were not removed",
                   isPresented: Binding(get: { !failures.isEmpty }, set: { if !$0 { failures = [] } })) {
                Button("Remove Anyway", role: .destructive) {
                    let items = failures.map(\.item)
                    failures = []
                    // Whatever still fails now (an agent's process holding a file, say) is reported
                    // again, with the same offer.
                    Task { failures = await store.removeWorktrees(items, force: true) }
                }
                Button("Keep", role: .cancel) { failures = [] }
            } message: {
                Text(failureMessage)
            }
    }
}

extension View {
    func removingWorktrees(_ pending: Binding<[TaskWorktree]>) -> some View {
        modifier(RemoveWorktrees(pending: pending))
    }
}
