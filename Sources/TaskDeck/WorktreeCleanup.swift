import SwiftUI

/// A worktree in Orca and the task it belongs to.
struct TaskWorktree: Hashable, Identifiable {
    let taskId: UUID
    let session: AgentSession
    var id: String { session.worktreeId ?? session.id.uuidString }
}

/// Asks before removing worktrees in Orca, removes them, and says which ones Orca refused.
/// Set `pending` to start; it is emptied once the user answers.
private struct RemoveWorktrees: ViewModifier {
    @Environment(AppStore.self) private var store
    @Binding var pending: [TaskWorktree]
    @State private var failures: [String] = []

    private var title: String {
        pending.count == 1 ? "Remove the worktree “\(pending[0].session.name)”?" : "Remove \(pending.count) worktrees?"
    }

    private var message: String {
        var lines: [String] = []
        if pending.count > 1 {
            lines.append(pending.prefix(6).map { "\($0.session.repoName) · \($0.session.name)" }.joined(separator: "\n")
                         + (pending.count > 6 ? "\n…and \(pending.count - 6) more" : ""))
        }
        lines.append("The checkout is deleted and the worktree leaves Orca. One with uncommitted changes is kept, "
                     + "and so is any branch Orca cannot tell is merged.")
        return lines.joined(separator: "\n\n")
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
                Button("OK") { failures = [] }
            } message: {
                Text(failures.joined(separator: "\n\n"))
            }
    }
}

extension View {
    func removingWorktrees(_ pending: Binding<[TaskWorktree]>) -> some View {
        modifier(RemoveWorktrees(pending: pending))
    }
}
