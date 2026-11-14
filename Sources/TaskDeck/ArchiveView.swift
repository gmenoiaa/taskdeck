import SwiftUI

/// Tasks archived from a Done column: browse them, see their time, restore or delete.
struct ArchiveView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var deleting: TaskItem?

    private func lastActivity(_ task: TaskItem) -> Date {
        task.entries.map { $0.end ?? $0.start }.max() ?? task.createdAt
    }

    private var archived: [TaskItem] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.tasks
            .filter { $0.archived }
            .filter { needle.isEmpty || $0.title.lowercased().contains(needle) || $0.ref.lowercased().contains(needle) }
            .sorted { lastActivity($0) > lastActivity($1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Archived tasks").font(.title3.weight(.semibold))
                Text("\(archived.count)")
                    .font(.caption).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            .padding(14)
            Divider()

            if archived.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "No archived tasks" : "No results",
                    systemImage: "archivebox",
                    description: Text(search.isEmpty ? "Tasks you archive from a Done column show up here." : "Nothing matches this filter."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(archived) { task in
                        row(task)
                    }
                }
                .softScrollEdges()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .actionBar()
        }
        .frame(width: 680, height: 560)
        .confirmationDialog(
            "Delete “\(deleting?.title ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete task", role: .destructive) {
                if let deleting { store.delete(task: deleting.id) }
                deleting = nil
            }
        } message: {
            Text("Its tracked time is deleted too. This cannot be undone.")
        }
    }

    private func row(_ task: TaskItem) -> some View {
        let project = store.project(task.projectId)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let project {
                        Text(project.name)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(project.color.opacity(0.18), in: Capsule())
                            .foregroundStyle(project.color)
                    }
                    if !task.displayRef.isEmpty {
                        if let url = URL(string: task.url), !task.url.isEmpty {
                            TicketLink(text: task.displayRef, url: url, space: project).font(.caption.weight(.medium))
                        } else {
                            Text(task.displayRef).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    if let status = task.remoteStatus, !status.isEmpty {
                        Text(status.prefix(1).uppercased() + status.dropFirst())
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(task.title.isEmpty ? "(untitled)" : task.title).lineLimit(2)
                Text("Tracked \(Fmt.short(task.total(now: Date()))) · last activity \(lastActivity(task).formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Restore") { store.unarchive(task.id) }
                .help("Put this task back on the board, in the column it was in")
            Button(role: .destructive) { deleting = task } label: { Image(systemName: "trash") }
                .help("Delete permanently")
        }
        .padding(.vertical, 4)
    }
}
