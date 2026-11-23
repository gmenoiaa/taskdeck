import SwiftUI

/// A ticket description in Markdown, with a preview of how it reads.
struct DescriptionField: View {
    @Binding var text: String
    @State private var preview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Description")
                Spacer()
                Picker("", selection: $preview) {
                    Text("Write").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Group {
                if preview {
                    ScrollView {
                        MarkdownView(text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "*No description.*" : text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                } else {
                    TextEditor(text: $text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                }
            }
            .frame(height: 170)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            Text("Markdown. Converted to the tracker's own format when the ticket is created.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A rough note in, a ticket title and description out.
struct DraftWithClaude: View {
    @Environment(AppStore.self) private var store
    @Binding var title: String
    @Binding var description: String
    let tracker: TrackerKind?
    @State private var note = ""
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        TextField("Note", text: $note,
                  prompt: Text("What needs doing? Paste messages, logs or links as context."),
                  axis: .vertical)
            .lineLimit(3...8)
        HStack(alignment: .firstTextBaseline) {
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            } else {
                // The UI promises that private notes never reach the AI.
                Text("Only this note and the title and description above are sent to Claude.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await generate() }
            } label: {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Generate", systemImage: "sparkles")
                }
            }
            .disabled(working || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Write the title and description from this note. Replaces what is there now.")
        }
    }

    private func generate() async {
        working = true
        failure = nil
        defer { working = false }
        do {
            let draft = try await Claude.draftTicket(note: note, title: title, description: description,
                                                     tracker: tracker, model: store.claudeModel,
                                                     instructions: store.aiInstructions)
            if !draft.title.isEmpty { title = draft.title }
            description = draft.description
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Creates the ticket of a task that has none yet in its space's tracker, then links the task to it.
struct CreateTicketView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskId: UUID

    @State private var targets: [CreateTarget] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var target: String?
    @State private var types: [TrackerChoice] = []
    @State private var loadingTypes = false
    @State private var type: String?
    @State private var assignToMe = true
    @State private var title = ""
    @State private var description = ""
    @State private var sending = false
    @State private var failure: String?
    /// Set when the ticket was created but a later step was not: the sheet stays open to say so.
    @State private var warning: String?

    private var task: TaskItem? { store.task(taskId) }
    private var project: Project? { store.project(task?.projectId) }
    private var kind: TrackerKind { project?.kind ?? .other }
    private var targetLabel: String { kind == .github ? "Repository" : "Project" }

    private var ready: Bool {
        target != nil && !title.trimmingCharacters(in: .whitespaces).isEmpty && !sending && !loadingTypes
            && (kind != .jira || type != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if let project {
                        LabeledContent("Space") { Text("\(project.name) · \(project.kind.label)") }
                    }
                    if loading {
                        LabeledContent(targetLabel) { ProgressView().controlSize(.small) }
                    } else if let loadError {
                        Text(loadError).font(.caption).foregroundStyle(.red)
                    } else {
                        Picker(targetLabel, selection: $target) {
                            Text("Choose…").tag(String?.none)
                            ForEach(targets) { Text($0.name).tag(String?.some($0.id)) }
                        }
                    }
                    if loadingTypes {
                        LabeledContent("Type") { ProgressView().controlSize(.small) }
                    } else if !types.isEmpty {
                        Picker("Type", selection: $type) {
                            ForEach(types) { Text($0.name).tag(String?.some($0.id)) }
                        }
                    }
                    Toggle("Assign to me", isOn: $assignToMe)
                }
                Section {
                    TextField("Title", text: $title)
                    DescriptionField(text: $description)
                }
                if let failure {
                    Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                if warning != nil {
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button {
                        Task { await send() }
                    } label: {
                        if sending { ProgressView().controlSize(.small) } else { Text("Create in \(kind.label)") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
                }
            }
            .padding(14)
        }
        .frame(width: 560, height: 600)
        .task { await load() }
        .onChange(of: target) { Task { await loadTypes() } }
    }

    private func load() async {
        guard let task, let project else {
            loading = false
            loadError = "This task is in no space with a tracker."
            return
        }
        title = task.title
        description = task.draft ?? ""
        do {
            targets = try await TicketFetcher.createTargets(project: project)
            if let last = project.createTarget, targets.contains(where: { $0.id == last }) {
                target = last
            } else if targets.count == 1 {
                target = targets[0].id
            }
            if targets.isEmpty { loadError = "\(project.kind.label) lists no \(targetLabel.lowercased()) where you can create a ticket." }
        } catch {
            loadError = "Could not read the \(targetLabel.lowercased())s: \(error.localizedDescription)"
        }
        loading = false
    }

    private func loadTypes() async {
        types = []
        type = nil
        guard let project, let target, let chosen = targets.first(where: { $0.id == target }) else { return }
        var list = chosen.types ?? []
        if chosen.types == nil {
            loadingTypes = true
            defer { loadingTypes = false }
            do {
                list = try await TicketFetcher.createTypes(project: project, target: target)
            } catch {
                failure = "Could not read the ticket types: \(error.localizedDescription)"
                return
            }
            if let i = targets.firstIndex(where: { $0.id == target }) { targets[i].types = list }
        }
        // The user may have picked another target while the types loaded.
        guard self.target == target else { return }
        types = list
        type = list.first { $0.id == project.createType }?.id
            ?? list.first { $0.name.caseInsensitiveCompare("Task") == .orderedSame }?.id
            ?? list.first?.id
    }

    private func send() async {
        guard var local = task, var project, let target else { return }
        // Kept on the task first, so nothing typed here is lost if the tracker refuses.
        local.title = title.trimmingCharacters(in: .whitespaces)
        local.draft = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description
        store.upsert(local)
        sending = true
        failure = nil
        defer { sending = false }
        do {
            let created = try await TicketFetcher.createTicket(project: project, target: target, type: type,
                                                               title: local.title, markdown: description,
                                                               assignToMe: assignToMe)
            // Read again: a timer may have started or the card moved while the request ran.
            if var now = store.task(taskId) {
                now.ref = created.ref
                now.url = created.url
                now.draft = nil
                now.remoteStatus = nil
                store.upsert(now)
            }
            project.createTarget = target
            project.createType = type
            store.upsert(project)
            Task { await store.refreshRemoteStatuses() }
            if let w = created.warning { warning = w } else { dismiss() }
        } catch {
            failure = error.localizedDescription
        }
    }
}
