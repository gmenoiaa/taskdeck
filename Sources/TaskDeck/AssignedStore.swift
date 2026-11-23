import Foundation

/// What the trackers list as assigned to me: kept between launches so the screen opens with the
/// last answer, read again in the background, and compared with the last look to report new ones.
extension AppStore {
    private static var assignedURL: URL {
        dataURL.deletingLastPathComponent().appendingPathComponent("assigned.json")
    }

    func loadAssigned() {
        guard let data = try? Data(contentsOf: Self.assignedURL),
              let saved = try? JSONDecoder().decode([String: [RemoteTicket]].self, from: data) else { return }
        // Pull requests saved before the list was limited to issues would show until the next refresh.
        assignedTickets = Dictionary(uniqueKeysWithValues: saved.compactMap { key, list in
            UUID(uuidString: key).map { ($0, list.filter { $0.status != "Open PR" }) }
        })
    }

    private func saveAssigned() {
        let byName = Dictionary(uniqueKeysWithValues: assignedTickets.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(byName) { try? data.write(to: Self.assignedURL, options: .atomic) }
    }

    private var onBoardIds: Set<String> {
        Set(tasks.map { "\($0.projectId?.uuidString ?? "")|\($0.ref.lowercased())" })
    }

    /// Tickets assigned to me that still need a decision: not on the board and not ignored.
    var assignedPending: [RemoteTicket] {
        let onBoard = onBoardIds
        return projects.flatMap { assignedTickets[$0.id] ?? [] }
            .filter { !onBoard.contains($0.id) && !ignoredAssigned.contains($0.id) }
    }

    func setIgnored(_ ticket: RemoteTicket, _ ignored: Bool) {
        if ignored { ignoredAssigned.insert(ticket.id) } else { ignoredAssigned.remove(ticket.id) }
        save()
    }

    /// Asks every tracker again. A tracker that cannot be read keeps its last list and reports why.
    func refreshAssigned() async {
        guard !refreshingAssigned else { return }
        refreshingAssigned = true
        defer { refreshingAssigned = false }
        let sources = projects.filter { $0.kind != .other }
        var complete = !sources.isEmpty
        await withTaskGroup(of: (UUID, Result<[RemoteTicket], Error>).self) { group in
            for project in sources {
                group.addTask {
                    do { return (project.id, .success(try await TicketFetcher.assigned(project: project))) }
                    catch { return (project.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let list):
                    assignedTickets[id] = list
                    assignedErrors[id] = nil
                case .failure(let error):
                    assignedErrors[id] = error.localizedDescription
                    complete = false
                }
            }
        }
        // Lists of spaces that no longer exist would otherwise stay in the file for ever.
        let known = Set(projects.map(\.id))
        assignedTickets = assignedTickets.filter { known.contains($0.key) }
        saveAssigned()
        noticeNewAssignments(complete: complete)
    }

    /// Reports tickets that were not assigned to me at the last look. The very first look only
    /// takes note, so the whole backlog is not reported; ignored tickets never are.
    private func noticeNewAssignments(complete: Bool) {
        let current = projects.flatMap { assignedTickets[$0.id] ?? [] }
        let ids = Set(current.map(\.id))
        guard let known = knownAssigned else {
            // Only a full answer is a fair starting point; a partial one would report the rest later.
            if complete {
                knownAssigned = ids
                save()
            }
            return
        }
        guard ids != known else { return }
        // What is assigned now, not everything ever seen: a ticket handed to someone else and
        // then back to me is news again. A tracker that failed keeps its last list in
        // `assignedTickets`, so its tickets are not forgotten by one bad answer.
        knownAssigned = ids
        save()
        // On the board or not: a card already there is the usual case of a ticket coming back.
        let fresh = current.filter { !known.contains($0.id) && !ignoredAssigned.contains($0.id) }
        guard notify.assigned, !fresh.isEmpty else { return }
        let lines = fresh.prefix(4).map { "\($0.displayRef) \($0.title)" }.joined(separator: "\n")
        Notifier.send(title: fresh.count == 1 ? "Ticket assigned to you" : "\(fresh.count) tickets assigned to you",
                      body: lines + (fresh.count > 4 ? "\n…" : ""))
    }
}
