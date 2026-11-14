import SwiftUI

/// Lists open tickets assigned to me in each tracker and adds the chosen ones to the board.
struct ImportView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var filter: UUID?
    @State private var search = ""
    @State private var tickets: [UUID: [RemoteTicket]] = [:]
    @State private var errors: [UUID: String] = [:]
    @State private var selected: Set<String> = []
    @State private var loading = false
    @State private var loadedOnce = false
    /// Spaces whose "Already on board" list is open. Closed to start with: those need no decision.
    @State private var showingOnBoard: Set<UUID> = []

    private var sources: [Project] {
        store.projects.filter { $0.kind != .other && (filter == nil || $0.id == filter) }
    }

    private func onBoard(_ t: RemoteTicket) -> Bool {
        store.tasks.contains { $0.projectId == t.projectId && $0.ref.lowercased() == t.ref.lowercased() }
    }

    private func visible(_ project: Project) -> [RemoteTicket] {
        let all = tickets[project.id] ?? []
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.title.lowercased().contains(needle) || $0.ref.lowercased().contains(needle)
                || $0.context.lowercased().contains(needle)
        }
    }

    private func fresh(_ project: Project) -> [RemoteTicket] { visible(project).filter { !onBoard($0) } }
    private func known(_ project: Project) -> [RemoteTicket] { visible(project).filter(onBoard) }

    /// Tickets not on the board yet, across the spaces shown and regardless of the filter text.
    private var newCount: Int {
        sources.flatMap { tickets[$0.id] ?? [] }.filter { !onBoard($0) }.count
    }

    private var selectable: [RemoteTicket] {
        sources.flatMap { visible($0) }.filter { !onBoard($0) }
    }

    private var chosen: [RemoteTicket] {
        sources.flatMap { tickets[$0.id] ?? [] }.filter { selected.contains($0.id) && !onBoard($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Assigned to me").font(.title3.weight(.semibold))
                if !loading, !tickets.isEmpty {
                    Text(newCount == 0 ? "nothing new" : "\(newCount) new")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
                Picker("", selection: $filter) {
                    Text("All spaces").tag(UUID?.none)
                    ForEach(store.projects.filter { $0.kind != .other }) { p in
                        Text(p.name).tag(UUID?.some(p.id))
                    }
                }
                .labelsHidden().frame(width: 170)
                Button { Task { await load() } } label: {
                    // The spinner takes the icon's place while loading.
                    ZStack {
                        Image(systemName: "arrow.clockwise").opacity(loading ? 0 : 1)
                        if loading { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(loading).help("Refresh")
            }
            .padding(14)
            Divider()

            List {
                ForEach(sources) { project in
                    Section {
                        if let error = errors[project.id] {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.red)
                        } else if tickets[project.id] == nil {
                            HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
                        } else if visible(project).isEmpty {
                            Text(search.isEmpty ? "Nothing open assigned to you." : "No results for this filter.")
                                .foregroundStyle(.secondary)
                        } else if fresh(project).isEmpty {
                            Text(search.isEmpty ? "Everything assigned to you here is already on the board."
                                                : "No new tickets for this filter.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(fresh(project)) { ticket in
                            row(ticket)
                        }
                        let onBoard = known(project)
                        if !onBoard.isEmpty {
                            // Open while filtering, so a ticket searched for is never hidden.
                            let open = showingOnBoard.contains(project.id) || !search.trimmingCharacters(in: .whitespaces).isEmpty
                            Button {
                                showingOnBoard.formSymmetricDifference([project.id])
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .rotationEffect(.degrees(open ? 90 : 0))
                                    Text("Already on board (\(onBoard.count))")
                                    Spacer()
                                }
                                .font(.callout).foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if open {
                                ForEach(onBoard) { ticket in
                                    row(ticket)
                                }
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Circle().fill(project.color).frame(width: 8, height: 8)
                            Text("\(project.name) · \(project.kind.label)")
                            if let list = tickets[project.id] {
                                let new = list.filter { !onBoard($0) }.count
                                Text(new == 0 ? "(\(list.count))" : "(\(new) new of \(list.count))")
                            }
                        }
                    }
                }
                if sources.isEmpty {
                    Text("No space with a tracker integration configured.").foregroundStyle(.secondary)
                }
            }
            .softScrollEdges()
            .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("Select all") { selected.formUnion(selectable.map(\.id)) }
                    .disabled(selectable.isEmpty)
                Button("Clear selection") { selected.removeAll() }
                    .disabled(selected.isEmpty)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Add to board" : "Add \(chosen.count) to board") { addChosen() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
                    .primaryGlass()
            }
            .actionBar()
            // A solid bar here: the rows under floating buttons were unreadable, and the last ones
            // could not be reached.
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            }
        }
        .frame(width: 720, height: 600)
        .task {
            if !loadedOnce { await load() }
        }
    }

    private func row(_ ticket: RemoteTicket) -> some View {
        let exists = onBoard(ticket)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            if exists {
                // Nothing to decide for these, so no checkbox: a ticked one read as "selected".
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .frame(width: 16)
            } else {
                Toggle("", isOn: Binding(
                    get: { selected.contains(ticket.id) },
                    set: { on in
                        if on { selected.insert(ticket.id) } else { selected.remove(ticket.id) }
                    }))
                    .labelsHidden()
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                // On the first line's baseline, so the reference stays beside the start of a long title.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let url = URL(string: ticket.url) {
                        TicketLink(text: ticket.displayRef, url: url, space: store.project(ticket.projectId))
                            .font(.callout.weight(.medium))
                            .fixedSize()
                    }
                    Text(ticket.title).lineLimit(2)
                        .foregroundStyle(exists ? .secondary : .primary)
                }
                Text([ticket.context, ticket.status, ticket.updated].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !exists else { return }
            if selected.contains(ticket.id) { selected.remove(ticket.id) } else { selected.insert(ticket.id) }
        }
    }

    private func addChosen() {
        for t in chosen {
            // GitHub's list only says "open"; the refresh below fetches the real state (draft, merged…).
            let known = store.project(t.projectId)?.kind == .github ? nil : t.status
            store.upsert(TaskItem(projectId: t.projectId, ref: t.ref, title: t.title, url: t.url,
                                  status: store.defaultColumnId, remoteStatus: known))
        }
        selected.removeAll()
        Task { await store.refreshRemoteStatuses() }
    }

    private func load() async {
        loadedOnce = true
        loading = true
        defer { loading = false }
        let projects = store.projects.filter { $0.kind != .other }
        tickets = [:]
        errors = [:]
        await withTaskGroup(of: (UUID, Result<[RemoteTicket], Error>).self) { group in
            for project in projects {
                group.addTask {
                    do { return (project.id, .success(try await TicketFetcher.assigned(project: project))) }
                    catch { return (project.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let list): tickets[id] = list
                case .failure(let error): errors[id] = error.localizedDescription
                }
            }
        }
    }
}
