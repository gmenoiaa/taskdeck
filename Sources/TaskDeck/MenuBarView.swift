import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    private var running: [TaskItem] { store.runningTasks }
    /// Shown only when nothing is running: the tasks most likely to be picked up next —
    /// most recently worked on first, then In progress columns, then the rest in board order.
    /// Done and Watching columns are never suggested.
    private var suggestions: [TaskItem] {
        var rank: [String: Int] = [:]
        for (index, column) in store.columns.enumerated() {
            rank[column.id] = column.role == .inProgress ? -1 : index
        }
        func lastWorked(_ t: TaskItem) -> Date { t.entries.compactMap(\.end).max() ?? .distantPast }
        return Array(store.tasks
            .filter {
                let role = store.role(of: $0.status)
                return !$0.archived && role != .done && role != .watching
            }
            .sorted {
                let (a, b) = (lastWorked($0), lastWorked($1))
                if a != b { return a > b }
                return (rank[$0.status] ?? 99, $0.order) < (rank[$1.status] ?? 99, $1.order)
            }
            .prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TaskDeck").font(.headline)
                Spacer()
                Text("Today: \(Fmt.short(store.trackedToday(now: store.now)))")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !running.isEmpty {
                        sectionTitle("Running")
                        ForEach(running) { MenuTaskRow(task: $0) }
                    }
                    if running.isEmpty && !suggestions.isEmpty {
                        sectionTitle("Suggestions")
                        ForEach(suggestions) { MenuTaskRow(task: $0) }
                    }
                    if running.isEmpty && suggestions.isEmpty {
                        Text("No open tasks.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                Button("Open board") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                if !running.isEmpty {
                    Button("Pause all") { store.stopAll() }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding(10)
        }
        .frame(width: 340)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
    }
}

struct MenuTaskRow: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    var body: some View {
        let project = store.project(task.projectId)
        let running = task.isRunning
        HStack(spacing: 8) {
            Circle().fill(project?.color ?? .gray).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title.isEmpty ? "(untitled)" : task.title).lineLimit(1)
                Text([project?.name, task.displayRef.isEmpty ? nil : task.displayRef, store.column(task.status)?.displayName]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(running ? Fmt.clock(task.currentStretch(now: store.now)) : Fmt.short(task.total(now: Date())))
                .font(.callout).monospacedDigit()
                .foregroundStyle(running ? Theme.accent : Color.secondary)
            Button {
                store.toggleTimer(task.id)
            } label: {
                Image(systemName: running ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }
}
