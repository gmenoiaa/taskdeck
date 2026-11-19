import SwiftUI

/// Lists open tickets assigned to me in each tracker and adds the chosen ones to the board.
struct ImportView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var filter: UUID?
    @State private var search = ""
    @State private var selected: Set<String> = []
    /// Spaces whose "Ignored" list is open.
    @State private var showingIgnored: Set<UUID> = []
    /// Spaces whose "Already on board" list is open. Closed to start with: those need no decision.
    @State private var showingOnBoard: Set<UUID> = []
    /// The row the keyboard is on.
    @State private var cursor: String?

    /// The rows on screen, top to bottom, as the list draws them.
    private var rows: [RemoteTicket] {
        let filtering = !search.trimmingCharacters(in: .whitespaces).isEmpty
        return sources.flatMap { project -> [RemoteTicket] in
            fresh(project)
                + (filtering || showingOnBoard.contains(project.id) ? known(project) : [])
                + (filtering || showingIgnored.contains(project.id) ? setAside(project) : [])
        }
    }

    /// Up and down move along the rows, also while the filter field has the keyboard. The rest
    /// needs the field empty or elsewhere, so a space or a letter typed into it stays text.
    private func key(_ event: NSEvent, inFilter: Bool) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        let rows = rows
        let at = rows.firstIndex { $0.id == cursor }
        switch event.keyCode {
        // Tab goes from the filter to the rows and back. macOS alone would leave it in the
        // field: it only moves Tab between text fields, and this sheet has one.
        case 48:
            if inFilter {
                event.window?.makeFirstResponder(nil)
                if at == nil { cursor = rows.first?.id }
            } else {
                focusToolbarSearch(placeholder: "Filter")
            }
            return true
        case 125:
            guard !rows.isEmpty else { return false }
            cursor = rows[min((at ?? -1) + 1, rows.count - 1)].id
            return true
        case 126:
            guard !rows.isEmpty else { return false }
            cursor = rows[max((at ?? 1) - 1, 0)].id
            return true
        default: break
        }
        guard let at, !(inFilter && !search.isEmpty) else { return false }
        let ticket = rows[at]
        let exists = onBoard(ticket), aside = ignored(ticket)
        switch event.keyCode {
        case 49:
            guard !exists, !aside else { return false }
            selected.formSymmetricDifference([ticket.id])
        case 36, 76:
            // With nothing ticked, Return adds the row the keyboard is on.
            guard chosen.isEmpty, !exists, !aside else { return false }
            selected.insert(ticket.id)
            addChosen()
        default:
            guard !inFilter, event.charactersIgnoringModifiers?.lowercased() == "i", !exists else { return false }
            selected.remove(ticket.id)
            store.setIgnored(ticket, !aside)
            // Stay in place: the next row moves up under the keyboard.
            cursor = rows.indices.contains(at + 1) ? rows[at + 1].id : (at > 0 ? rows[at - 1].id : nil)
        }
        return true
    }

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

    // The last answer lives in the store, so the screen opens with it and is repainted when the
    // trackers answer again.
    private var tickets: [UUID: [RemoteTicket]] { store.assignedTickets }
    private var errors: [UUID: String] { store.assignedErrors }
    private var loading: Bool { store.refreshingAssigned }

    private func ignored(_ t: RemoteTicket) -> Bool { store.ignoredAssigned.contains(t.id) }
    private func fresh(_ project: Project) -> [RemoteTicket] { visible(project).filter { !onBoard($0) && !ignored($0) } }
    private func known(_ project: Project) -> [RemoteTicket] { visible(project).filter(onBoard) }
    /// Ignored and not on the board: one put on the board by hand is simply on the board.
    private func setAside(_ project: Project) -> [RemoteTicket] { visible(project).filter { ignored($0) && !onBoard($0) } }

    /// Tickets not on the board yet, across the spaces shown and regardless of the filter text.
    private var newCount: Int {
        sources.flatMap { tickets[$0.id] ?? [] }.filter { !onBoard($0) && !ignored($0) }.count
    }

    private var selectable: [RemoteTicket] {
        sources.flatMap { visible($0) }.filter { !onBoard($0) && !ignored($0) }
    }

    private var chosen: [RemoteTicket] {
        sources.flatMap { tickets[$0.id] ?? [] }.filter { selected.contains($0.id) && !onBoard($0) && !ignored($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Assigned to me").font(.title3.weight(.semibold))
                if !tickets.isEmpty {
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
                Button { Task { await store.refreshAssigned() } } label: {
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

            ScrollViewReader { list in
            List {
                ForEach(sources) { project in
                    Section {
                        if let error = errors[project.id] {
                            // The list under it, if any, is the last one that could be read.
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.red)
                        }
                        if tickets[project.id] == nil {
                            if errors[project.id] == nil {
                                HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
                            }
                        } else if visible(project).isEmpty {
                            Text(search.isEmpty ? "Nothing open assigned to you." : "No results for this filter.")
                                .foregroundStyle(.secondary)
                        } else if fresh(project).isEmpty {
                            Text(search.isEmpty ? "Nothing new: everything assigned to you here is on the board or ignored."
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
                        let aside = setAside(project)
                        if !aside.isEmpty {
                            let open = showingIgnored.contains(project.id) || !search.trimmingCharacters(in: .whitespaces).isEmpty
                            Button {
                                showingIgnored.formSymmetricDifference([project.id])
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .rotationEffect(.degrees(open ? 90 : 0))
                                    Text("Ignored (\(aside.count))")
                                    Spacer()
                                }
                                .font(.callout).foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if open {
                                ForEach(aside) { ticket in
                                    row(ticket)
                                }
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Circle().fill(project.color).frame(width: 8, height: 8)
                            Text("\(project.name) · \(project.kind.label)")
                            if let list = tickets[project.id] {
                                let new = list.filter { !onBoard($0) && !ignored($0) }.count
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
            .onChange(of: cursor) { _, new in
                if let new { list.scrollTo(new) }
            }
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
        }
        .frame(width: 720, height: 600)
        .background(KeyCatcher(field: "Filter", handler: { key($0, inFilter: $1) }))
        // Not tied to the sheet's life: closing it mid-way would cancel the requests and show them as errors.
        .onAppear { Task { await store.refreshAssigned() } }
    }

    private func row(_ ticket: RemoteTicket) -> some View {
        let exists = onBoard(ticket)
        let aside = !exists && ignored(ticket)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            if aside {
                Image(systemName: "eye.slash")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(width: 16)
            } else if exists {
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
                        .foregroundStyle(exists || aside ? .secondary : .primary)
                }
                Text([ticket.type ?? "", ticket.context, ticket.status, ticket.updated].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if aside {
                Button("Restore") { store.setIgnored(ticket, false) }
                    .buttonStyle(.borderless).tint(nil)
                    .help("Put it back in the list of new tickets")
            } else if !exists {
                Button("Ignore") {
                    selected.remove(ticket.id)
                    store.setIgnored(ticket, true)
                }
                .buttonStyle(.borderless).tint(nil)
                .help("Hide this ticket here and send no notification about it. It can be restored from “Ignored”.")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .id(ticket.id)
        .listRowBackground(cursor == ticket.id ? Theme.accent.opacity(0.12) : nil)
        .onTapGesture {
            cursor = ticket.id
            guard !exists, !aside else { return }
            if selected.contains(ticket.id) { selected.remove(ticket.id) } else { selected.insert(ticket.id) }
        }
    }

    private func addChosen() {
        for t in chosen {
            // GitHub's list only says "open"; the refresh below fetches the real state (draft, merged…).
            let known = store.project(t.projectId)?.kind == .github ? nil : t.status
            store.upsert(TaskItem(projectId: t.projectId, ref: t.ref, title: t.title, url: t.url,
                                  status: store.defaultColumnId, remoteStatus: known, remoteType: t.type))
        }
        selected.removeAll()
        Task { await store.refreshRemoteStatuses() }
    }
}
