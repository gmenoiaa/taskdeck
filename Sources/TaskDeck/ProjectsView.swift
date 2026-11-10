import SwiftUI

/// The Projects tab of the Settings window.
struct ProjectsView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: Project?
    @State private var deleting: Project?

    var body: some View {
        VStack(spacing: 0) {
            if store.projects.isEmpty {
                ContentUnavailableView("No projects", systemImage: "folder",
                                       description: Text("Create a project for each company/tracker."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.projects) { p in
                        HStack(spacing: 10) {
                            Circle().fill(p.color).frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.body.weight(.medium))
                                Text(p.baseURL.isEmpty ? "\(p.kind.label) · no base URL" : "\(p.kind.label) · \(p.baseURL)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Edit") { editing = p }
                            Button(role: .destructive) { deleting = p } label: { Image(systemName: "trash") }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            Divider()
            HStack {
                Text("One project per company or tracker. Each holds its base URL and credentials.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { editing = Project(colorIndex: store.projects.count) } label: {
                    Label("New project", systemImage: "plus")
                }
            }
            .padding(14)
        }
        .sheet(item: $editing) { p in
            ProjectEditor(project: p).environment(store)
        }
        .confirmationDialog(
            "Delete project \(deleting?.name ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete project", role: .destructive) {
                if let deleting { store.delete(project: deleting) }
                deleting = nil
            }
        } message: {
            Text("Tasks are kept, but left without a project.")
        }
    }
}

struct ProjectEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var project: Project
    @State private var apiKey = ""
    @State private var activities: [RedmineClient.Activity] = []
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    init(project: Project) {
        _project = State(initialValue: project)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $project.name, prompt: Text("Company / project"))
                Picker("Tracker", selection: $project.kind) {
                    ForEach(TrackerKind.allCases) { Text($0.label).tag($0) }
                }
                TextField("Base URL", text: $project.baseURL, prompt: Text(project.kind.urlHint))
                LabeledContent("Color") {
                    HStack(spacing: 6) {
                        ForEach(Project.palette.indices, id: \.self) { i in
                            Circle().fill(Project.palette[i])
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(Color.primary, lineWidth: project.colorIndex == i ? 2 : 0))
                                .onTapGesture { project.colorIndex = i }
                        }
                    }
                }
                if project.kind != .other {
                    Section(project.kind.label) {
                        if project.kind == .jira {
                            TextField("E-mail", text: Binding(get: { project.username ?? "" }, set: { project.username = $0 }),
                                      prompt: Text("Atlassian account (empty = Bearer token, Server/DC)"))
                        }
                        SecureField(project.kind == .redmine ? "API key" : "API token", text: $apiKey, prompt: Text(tokenHint))
                        HStack {
                            Button("Test connection") { Task { await test() } }
                                .disabled(testing || apiKey.isEmpty || project.baseURL.isEmpty)
                            if testing { ProgressView().controlSize(.small) }
                            if let testResult {
                                Text(testResult).font(.caption)
                                    .foregroundStyle(testOK ? .green : .red)
                            }
                        }
                        if project.kind == .redmine {
                            Picker("Text formatting", selection: Binding(
                                get: { project.textFormat ?? "textile" },
                                set: { project.textFormat = $0 })) {
                                Text("Textile").tag("textile")
                                Text("Markdown").tag("markdown")
                            }
                        }
                        if project.kind == .redmine, !activities.isEmpty {
                            Picker("Default activity", selection: $project.defaultActivityId) {
                                Text("Redmine default").tag(Int?.none)
                                ForEach(activities) { Text($0.name).tag(Int?.some($0.id)) }
                            }
                        }
                        Text(project.kind == .github
                             ? "Optional for public repositories. The token is stored in the macOS Keychain."
                             : "The key is stored in the macOS Keychain, not in the data file.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    project.name = project.name.trimmingCharacters(in: .whitespaces)
                    project.baseURL = project.baseURL.trimmingCharacters(in: .whitespaces)
                    if project.kind != .other {
                        Keychain.set(apiKey, account: project.keychainAccount)
                    }
                    store.upsert(project)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(project.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 480)
        .frame(minHeight: project.kind != .other ? 440 : 280)
        .onAppear {
            apiKey = Keychain.get(account: project.keychainAccount) ?? ""
        }
    }

    private var tokenHint: String {
        switch project.kind {
        case .redmine: return "My account → API access key"
        case .jira: return "id.atlassian.com → Security → API tokens"
        case .github: return "Personal access token (read issues/PRs)"
        case .other: return ""
        }
    }

    private func test() async {
        testing = true
        testResult = nil
        defer { testing = false }
        do {
            switch project.kind {
            case .redmine:
                activities = try await RedmineClient(baseURL: project.baseURL, apiKey: apiKey).activities()
                testResult = "Connected · \(activities.count) activities"
            case .jira:
                testResult = "Connected as \(try await TicketFetcher.jiraWhoAmI(project: project, token: apiKey))"
            case .github:
                testResult = "Connected as \(try await TicketFetcher.githubWhoAmI(project: project, token: apiKey))"
            case .other:
                break
            }
            testOK = true
        } catch {
            testOK = false
            testResult = error.localizedDescription
        }
    }
}
