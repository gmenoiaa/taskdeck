import SwiftUI

/// Makes a goal from a tracker's epic, parent issue or milestone, with the tickets under it as its
/// tasks. Opened on an imported goal, it reads the same ticket again to add children made since.
struct GoalImportView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// The goal to add to; nil makes a new one.
    let goalId: UUID?
    /// Called with the goal that received the tasks.
    var onDone: (UUID) -> Void = { _ in }

    @State private var spaceId: UUID?
    @State private var input = ""
    @State private var epic: EpicTickets?
    @State private var chosen: Set<String> = []
    @State private var loading = false
    @State private var error: String?

    private var spaces: [Project] { store.projects.filter { $0.kind != .other } }
    private var space: Project? { store.project(spaceId) }
    private var goal: Goal? { store.goal(goalId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(goal == nil ? "New goal from a tracker" : "Update “\(goal?.displayName ?? "")” from its tracker")
                    .font(.headline)
                Text("The tickets under an epic, parent issue or milestone become the goal's tasks.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker("Space", selection: $spaceId) {
                        ForEach(spaces) { Text("\($0.name) · \($0.kind.label)").tag(UUID?.some($0.id)) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(goal?.source != nil)
                    TextField("Parent", text: $input, prompt: Text(space.map { TicketFetcher.epicHint($0.kind) } ?? ""))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await fetch() } }
                        .disabled(goal?.source != nil)
                    Button("Fetch") { Task { await fetch() } }
                        .disabled(loading || space == nil || input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(16)
            Divider()
            list
            Divider()
            HStack {
                if let epic {
                    Text("\(chosen.count) of \(epic.children.count) chosen").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(goal == nil ? "Create Goal" : "Add Tasks", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(epic == nil || (goal != nil && chosen.isEmpty))
            }
            .padding(14)
        }
        .frame(width: 560, height: 520)
        .onAppear {
            if let source = goal?.source {
                spaceId = source.projectId
                input = source.url
                Task { await fetch() }
            } else {
                spaceId = spaces.first?.id
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let epic {
            List {
                Section {
                    if epic.children.isEmpty {
                        Text("Nothing is under this ticket.").foregroundStyle(.secondary)
                    }
                    ForEach(epic.children) { child in row(child) }
                } header: {
                    Text("\(epic.ref) — \(epic.title)").lineLimit(1)
                }
            }
            .listStyle(.inset)
        } else {
            Text(spaces.isEmpty ? "No space is linked to a tracker. Set one up in Settings → Spaces."
                                : "Choose the space, type the parent ticket and press Fetch.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
        }
    }

    private func row(_ child: EpicTickets.Child) -> some View {
        let existing = spaceId.flatMap { store.task(project: $0, ref: child.ref) }
        let inThisGoal = goalId != nil && existing?.goalId == goalId
        return Toggle(isOn: Binding(get: { inThisGoal || chosen.contains(child.id) },
                                    set: { on in if on { chosen.insert(child.id) } else { chosen.remove(child.id) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(child.displayRef)  \(child.title)").lineLimit(1)
                Text(note(child, existing: existing, inThisGoal: inThisGoal))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(inThisGoal)
    }

    private func note(_ child: EpicTickets.Child, existing: TaskItem?, inThisGoal: Bool) -> String {
        var parts = [child.type, child.status].compactMap { $0 }.filter { !$0.isEmpty }
        if inThisGoal {
            parts.append("already in this goal")
        } else if let existing {
            if let other = store.goal(existing.goalId) {
                parts.append("on the board, moves from “\(other.displayName)”")
            } else {
                parts.append(existing.archived ? "archived, joins the goal" : "on the board, joins the goal")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func fetch() async {
        guard let space else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await TicketFetcher.epic(project: space, input: input)
            epic = result
            // Open work is ticked; finished work and what is already in this goal are not.
            chosen = Set(result.children.filter { child in
                !child.closed && !(goalId != nil && store.task(project: space.id, ref: child.ref)?.goalId == goalId)
            }.map(\.id))
        } catch {
            epic = nil
            self.error = error.localizedDescription
        }
    }

    private func apply() {
        guard let epic, let space else { return }
        let picked = epic.children.filter { chosen.contains($0.id) }
        let id = store.importEpic(epic, project: space, children: picked, into: goalId)
        onDone(id)
        dismiss()
    }
}
