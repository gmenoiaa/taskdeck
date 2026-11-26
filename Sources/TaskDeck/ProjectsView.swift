import SwiftUI

/// The Spaces tab of the Settings window. A space is a `Project` in code and in the data file.
struct ProjectsView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: Project?
    @State private var deleting: Project?

    var body: some View {
        VStack(spacing: 0) {
            if store.projects.isEmpty {
                ContentUnavailableView("No spaces", systemImage: "folder",
                                       description: Text("Create a space for each company or area of work."))
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
                Text("One space per company or area of work. Each holds its tracker, credentials and agent settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { editing = Project(colorIndex: store.projects.count) } label: {
                    Label("New space", systemImage: "plus")
                }
            }
            .padding(14)
        }
        .sheet(item: $editing) { p in
            ProjectEditor(project: p).environment(store)
        }
        .confirmationDialog(
            "Delete space \(deleting?.name ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete space", role: .destructive) {
                if let deleting { store.delete(project: deleting) }
                deleting = nil
            }
        } message: {
            Text("Tasks are kept, but left without a space.")
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
                TextField("Name", text: $project.name, prompt: Text("Company or area of work"))
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
                Section("Daily target") {
                    TextField("Hours per working day", value: $project.dailyTargetHours,
                              format: .number.precision(.fractionLength(0...2)), prompt: Text("None"))
                    Text("Counts Monday to Friday. The overview draws it on the chart and shows what is left. Empty for no target.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                StandupSection(settings: Binding(get: { project.standup ?? StandupSettings() },
                                                 set: { project.standup = $0 }))
                if Browser.kinds.contains(where: \.isInstalled) {
                    Section("Links") {
                        Picker("Open links in", selection: Binding(
                            get: { project.browser ?? "" },
                            set: { project.browser = $0.isEmpty ? nil : $0; project.browserProfile = nil })) {
                            Text("Default browser").tag("")
                            ForEach(Browser.kinds.filter(\.isInstalled)) { Text($0.name).tag($0.id) }
                        }
                        if let kind = Browser.kind(project.browser) {
                            let profiles = Browser.profiles(of: kind)
                            let chosen = Binding(get: { project.browserProfile ?? "" },
                                                 set: { project.browserProfile = $0.isEmpty ? nil : $0 })
                            if profiles.isEmpty {
                                // The profile list could not be read; the folder name still works.
                                TextField("Profile folder", text: chosen, prompt: Text("Default, Profile 1, …"))
                                    .help("Shown as the last part of “Profile Path” on the browser's version page.")
                            } else {
                                Picker("Profile", selection: chosen) {
                                    Text("Last used").tag("")
                                    ForEach(profiles) { Text($0.name).tag($0.directory) }
                                }
                            }
                        }
                        Text("Tickets and pull requests of this space open there.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if Orca.isInstalled {
                    Section("Agent sessions") {
                        SpaceRepositories(
                            selection: Binding(get: { project.repoIds }, set: { project.orcaRepoIds = $0 }),
                            organisation: Binding(get: { project.githubOrg ?? "" },
                                                  set: { project.githubOrg = $0.isEmpty ? nil : $0 }))
                        TextField("Claude home", text: Binding(get: { project.claudeHome ?? "" }, set: { project.claudeHome = $0 }),
                                  prompt: Text("~/.claude (default)"))
                        GitHubAccountPicker(selection: Binding(get: { project.githubAccount ?? "" },
                                                               set: { project.githubAccount = $0.isEmpty ? nil : $0 }))
                        Text("The repositories are offered first when you start a session from one of this space's tasks, and their Orca worktrees named after a ticket show on that task. Sessions also use the directory Claude Code keeps its settings, MCP servers and logs in, and the account the agent's gh commands run as.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Review") {
                        Picker("Review sends", selection: Binding(get: { project.review },
                                                                  set: { project.reviewDetail = $0 == .status ? nil : $0.rawValue })) {
                            ForEach(ReviewDetail.allCases) { Text($0.label).tag($0) }
                        }
                        Text(project.review.hint + " One Claude login reviews every space (Settings, Agents), so this is what that login gets to see of this space.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("First message to the agent") {
                        TextEditor(text: Binding(get: { project.sessionPrompt ?? "" }, set: { project.sessionPrompt = $0 }))
                            .font(.callout.monospaced())
                            .frame(minHeight: 70)
                        Text("Leave empty for the standard message with the whole ticket. Otherwise write your own, for example “/implement-ticket {ref}”. "
                             + Orca.placeholders.map { "\($0.name) is \($0.meaning)" }.joined(separator: "; ")
                             + ". You can still edit the message each time you start a session.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("First message of a code review") {
                        TextEditor(text: Binding(get: { project.codeReviewPrompt ?? "" }, set: { project.codeReviewPrompt = $0 }))
                            .font(.callout.monospaced())
                            .frame(minHeight: 70)
                        Text("Leave empty for the one in Settings, Agents. It is used when a pull request is reviewed in this space (Tasks, Review a Pull Request). " + CodeReview.placeholderHelp)
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
                    let home = (project.claudeHome ?? "").trimmingCharacters(in: .whitespaces)
                    project.claudeHome = home.isEmpty ? nil : home
                    let prompt = (project.sessionPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    project.sessionPrompt = prompt.isEmpty ? nil : prompt
                    let review = (project.codeReviewPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    project.codeReviewPrompt = review.isEmpty ? nil : review
                    if let hours = project.dailyTargetHours, hours <= 0 { project.dailyTargetHours = nil }
                    if var standup = project.standup {
                        standup.instructions = standup.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Never set up: nothing worth keeping in the file. Turned off after a setup:
                        // the time and days stay for when it is turned on again.
                        project.standup = standup == StandupSettings() ? nil : standup
                    }
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
        // Room for the "Agent sessions" section when it is shown.
        // Capped: with every section showing it would be taller than a laptop screen. The form scrolls.
        .frame(minHeight: min(720, (project.kind != .other ? 440 : 280) + (Orca.isInstalled ? 370 : 0)))
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

/// A space's daily standup: whether it has one, when, and how its update should read.
struct StandupSection: View {
    @Binding var settings: StandupSettings

    /// The meeting time as a date today, for the time picker; only hour and minute are kept.
    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: Date()) ?? Date() },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                settings.hour = parts.hour ?? settings.hour
                settings.minute = parts.minute ?? settings.minute
            })
    }

    /// Weekday numbers in the order this Mac's calendar starts its week.
    private var weekOrder: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private func day(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { settings.weekdays.contains(weekday) },
            set: { on in
                settings.weekdays.removeAll { $0 == weekday }
                if on { settings.weekdays = (settings.weekdays + [weekday]).sorted() }
            })
    }

    var body: some View {
        Section("Daily standup") {
            Toggle("This space has a daily standup", isOn: $settings.enabled)
            if settings.enabled {
                DatePicker("Meeting time", selection: time, displayedComponents: .hourAndMinute)
                LabeledContent("Days") {
                    HStack(spacing: 4) {
                        ForEach(weekOrder, id: \.self) { weekday in
                            Toggle(isOn: day(weekday)) {
                                Text(Calendar.current.veryShortWeekdaySymbols[weekday - 1]).frame(minWidth: 14)
                            }
                            .toggleStyle(.button)
                            .help(Calendar.current.weekdaySymbols[weekday - 1])
                        }
                    }
                }
                Picker("Remind me", selection: $settings.remindMinutes) {
                    Text("No reminder").tag(0)
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) minutes before").tag($0) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Instructions for this space's update")
                    TextEditor(text: $settings.instructions)
                        .font(.callout)
                        .frame(minHeight: 60)
                }
                Text("For example: “In Portuguese. Three bullets per part at most. No time figures.” Added to the instructions in Settings → AI; where they disagree, these win.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.weekdays.isEmpty {
                    Label("No day is ticked, so there is no reminder and the update covers the last 24 hours.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}
