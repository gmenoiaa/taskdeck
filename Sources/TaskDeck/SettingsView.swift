import SwiftUI
import AppKit

/// App-wide settings (TaskDeck → Settings…, ⌘,): general options, board columns, projects and AI.
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "projects"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            BoardSettings()
                .tabItem { Label("Board", systemImage: "rectangle.split.3x1") }
                .tag("board")
            ProjectsView()
                .frame(width: 560, height: 420)
                .tabItem { Label("Projects", systemImage: "folder") }
                .tag("projects")
            AISettings()
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag("ai")
        }
    }
}

/// The board's columns: rename, reorder, add, delete, and say what each one means.
private struct BoardSettings: View {
    @Environment(AppStore.self) private var store
    @State private var deleting: BoardColumn?

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            List {
                ForEach($store.columns) { $column in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .help("Drag to reorder")
                        TextField("Name", text: $column.name)
                            .textFieldStyle(.roundedBorder)
                        Picker("Meaning", selection: $column.role) {
                            ForEach(ColumnRole.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        .help(column.role.hint)
                        Text("\(store.taskCount(in: column.id))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                            .help("Tasks in this column, archived ones included")
                        Button(role: .destructive) {
                            if store.taskCount(in: column.id) == 0 {
                                store.deleteColumn(column.id)
                            } else {
                                deleting = column
                            }
                        } label: { Image(systemName: "trash") }
                        .disabled(store.columns.count <= 1)
                        .help(store.columns.count <= 1 ? "The board needs at least one column" : "Delete this column")
                    }
                    .padding(.vertical, 2)
                }
                .onMove { store.columns.move(fromOffsets: $0, toOffset: $1) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(ColumnRole.allCases) { role in
                        (Text(role.label).fontWeight(.semibold) + Text(" — \(role.hint)"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Spacer()
                    Button { store.addColumn() } label: { Label("Add column", systemImage: "plus") }
                }
            }
            .padding(14)
        }
        .frame(width: 560, height: 460)
        .onChange(of: store.columns) { store.save() }
        .confirmationDialog(
            "Delete column “\(deleting?.displayName ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete column", role: .destructive) {
                if let deleting { store.deleteColumn(deleting.id) }
                deleting = nil
            }
        } message: {
            Text("Its \(deleting.map { store.taskCount(in: $0.id) } ?? 0) tasks are kept and moved to another column.")
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Timers") {
                Toggle("Only one timer at a time", isOn: $store.singleTimer)
            }
            Section("Data") {
                LabeledContent("Tasks and tracked time") {
                    Button("Show data file in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppStore.dataURL])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: store.singleTimer) { store.save() }
    }
}

private struct AISettings: View {
    @Environment(AppStore.self) private var store
    @State private var claudeKey = ""
    @State private var loaded = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Claude") {
                SecureField("API key", text: $claudeKey, prompt: Text("sk-ant-…"))
                Text("Used by “Explain” in the ticket details. Stored in the macOS Keychain. The ticket's text is sent to the Claude API only when you click Explain.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Model", selection: $store.claudeModel) {
                    ForEach(Claude.models) { Text($0.name).tag($0.id) }
                }
                if let model = Claude.models.first(where: { $0.id == store.claudeModel }) {
                    Text(model.note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Time entry comments") {
                Picker("Propose a comment", selection: $store.autoLogComment) {
                    Text("When I click Generate").tag(false)
                    Text("Automatically").tag(true)
                }
                Text("Automatically: Claude writes a proposal as soon as a log screen opens, one request per task listed. Either way the Generate button stays next to the comment field.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Instructions for the AI") {
                TextEditor(text: $store.aiInstructions)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 110, maxHeight: 220)
                Text("Added to every AI request and given priority over the built-in style rules. For example: “Answer in Brazilian Portuguese.” or “I work mostly on the backend; point out database and API impact.”")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            Claude.adoptLegacyKey(from: store.projects)
            claudeKey = Claude.apiKey() ?? ""
            loaded = true
        }
        .onChange(of: claudeKey) {
            guard loaded else { return }
            Keychain.set(claudeKey.trimmingCharacters(in: .whitespacesAndNewlines), account: Claude.keyAccount)
        }
        .onChange(of: store.claudeModel) { store.save() }
        .onChange(of: store.aiInstructions) { store.save() }
        .onChange(of: store.autoLogComment) { store.save() }
    }
}
