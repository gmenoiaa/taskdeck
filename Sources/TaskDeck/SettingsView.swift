import SwiftUI
import AppKit

/// App-wide settings (TaskDeck → Settings…, ⌘,): general options, notifications, board columns, spaces, agents and AI.
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "projects"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            NotificationSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag("notifications")
            BoardSettings()
                .tabItem { Label("Board", systemImage: "rectangle.split.3x1") }
                .tag("board")
            ProjectsView()
                .frame(width: 560, height: 420)
                .tabItem { Label("Spaces", systemImage: "folder") }
                .tag("projects")
            AgentSettings()
                .tabItem { Label("Agents", systemImage: "terminal") }
                .tag("agents")
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
                Toggle("Start the timer when a card moves to In progress", isOn: $store.notify.autoStartInProgress)
                Text("Not when the card comes from the agents' column: that was the agent's work, not yours starting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Forgotten timer") {
                Toggle("Remind me when I work with no timer", isOn: $store.notify.noTimer)
                if store.notify.noTimer {
                    Picker("After", selection: $store.notify.noTimerMinutes) {
                        ForEach([5, 10, 15, 20, 30], id: \.self) { Text("\($0) minutes at the Mac").tag($0) }
                    }
                    // One row for the two ends of the day.
                    LabeledContent("Working hours") {
                        HStack(spacing: 6) {
                            Picker("From", selection: $store.notify.workFrom) {
                                ForEach(5..<13, id: \.self) { Text("\($0):00").tag($0) }
                            }
                            Text("to").foregroundStyle(.secondary)
                            Picker("Until", selection: $store.notify.workTo) {
                                ForEach(13..<24, id: \.self) { Text("\($0):00").tag($0) }
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Toggle("Also at weekends", isOn: $store.notify.noTimerWeekends)
                }
                Text("A notification, and a marked clock in the menu bar, when you have been using the Mac that long with nothing tracked. Five minutes without touching it, a locked screen or sleep count as being away.")
                    .font(.caption).foregroundStyle(.secondary)
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
        .onChange(of: store.notify) { store.save() }
    }
}

private struct NotificationSettingsTab: View {
    @Environment(AppStore.self) private var store
    @State private var sent: [Notifier.Sent] = []
    @State private var blocked: String?

    var body: some View {
        @Bindable var store = store
        Form {
            if let blocked {
                Section {
                    Label(blocked, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Open Notification Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            Section("Sound") {
                Picker("Sound", selection: $store.notify.sound) {
                    Text("macOS default").tag("")
                    Text("None").tag("none")
                    if !Notifier.sounds.isEmpty { Divider() }
                    ForEach(Notifier.sounds, id: \.self) { Text($0).tag($0) }
                }
                // Heard while choosing, so picking one does not need a test notification.
                .onChange(of: store.notify.sound) { _, name in
                    if !name.isEmpty, name != "none" { NSSound(named: name)?.play() }
                }
                Text("Used by every notification from TaskDeck. Focus and the settings in System Settings → Notifications still decide whether it plays.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tickets and agents") {
                Toggle("Ticket assigned to me", isOn: $store.notify.assigned)
                    .help("Checked every 15 minutes while the app is open. Tickets you ignored are not reported.")
                Toggle("Pull request merged or closed", isOn: $store.notify.pullRequests)
                Toggle("Agent sessions", isOn: $store.notify.sessions)
                    .help("When an agent stops and it is your turn, when it opens a pull request, and when the agent queue cannot start a task or needs you to pick a repository.")
                Text("Tickets are checked every 15 minutes while the app is open. Agent sessions: when it is your turn, a pull request opens, or the queue needs you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Time") {
                Toggle("Time not logged yet", isOn: $store.notify.unlogged)
                if store.notify.unlogged {
                    Picker("Remind me from", selection: $store.notify.unloggedHour) {
                        ForEach(12..<24, id: \.self) { Text("\($0):00").tag($0) }
                    }
                }
                Toggle("Timer running for a long time", isOn: $store.notify.longTimer)
                if store.notify.longTimer {
                    Picker("Remind me every", selection: $store.notify.longTimerHours) {
                        ForEach(1...6, id: \.self) { Text($0 == 1 ? "1 hour" : "\($0) hours").tag($0) }
                    }
                }
                Text("The reminder about working with no timer is in General.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Daily standup") {
                Toggle("Before a space's standup", isOn: $store.notify.standup)
                Text("The meeting time, the days and how early to remind are set per space in Settings → Spaces.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dock badge") {
                Picker("Shows", selection: $store.notify.badge) {
                    Text("Things waiting for me").tag(NotificationSettings.DockBadge.waiting)
                    Text("Running timer").tag(NotificationSettings.DockBadge.timer)
                    Text("Nothing").tag(NotificationSettings.DockBadge.none)
                }
                if store.notify.badge == .waiting {
                    Toggle("Count tickets assigned to me that are not on the board", isOn: $store.notify.badgeAssigned)
                    Toggle("Count open pull requests", isOn: $store.notify.badgePullRequests)
                    Text("Always counted: sessions where it is your turn, and queued tasks that need a repository or did not start. Pull requests are the board's sessions', without drafts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Check") {
                LabeledContent("If nothing appears, look in System Settings → Notifications, and at Focus.") {
                    Button("Send a test") {
                        Notifier.send(title: "TaskDeck", body: "Notifications are working.")
                        sent = Notifier.recent()
                    }
                }
                DisclosureGroup("Recently sent (\(sent.count))") {
                    if sent.isEmpty {
                        Text("Nothing sent yet.").foregroundStyle(.secondary)
                    }
                    ForEach(sent) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(item.title).fontWeight(.medium)
                                Spacer()
                                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Text(item.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let problem = item.problem {
                                Text("macOS refused it: \(problem)").font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // A fixed height: the list of sent notifications scrolls inside it instead of growing the window.
        .frame(width: 560, height: 560)
        .task {
            sent = Notifier.recent()
            blocked = await Notifier.blocked()
        }
        .onChange(of: store.notify) { store.save() }
    }
}

private struct AgentSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Agent queue") {
                if !Orca.isInstalled {
                    Text("Agent sessions need Orca, which was not found on this Mac.").foregroundStyle(.secondary)
                } else if store.queueColumn == nil {
                    LabeledContent("Queue column") {
                        Button("Add a “For agents” column") { store.addQueueColumn() }
                    }
                    Text("A task dragged into that column is started as an agent session in Orca, without the Start session sheet, and then moves to In progress. Nothing starts by itself until the column exists.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Stepper("Sessions working at once: \(store.agentQueueLimit)",
                            value: $store.agentQueueLimit, in: 1...6)
                    Toggle("Run without asking for permission", isOn: $store.agentQueueSkipPermissions)
                    Text("On: the agent is started with Claude Code's --dangerously-skip-permissions, so it edits files and runs commands in the checkout without stopping to ask. The first message contains ticket text written by other people. Off: it stops at the first permission prompt and waits for you in Orca.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Ask Claude which repository a ticket is about", isOn: $store.agentQueueAskClaude)
                    Text("The queue first looks for a repository's name in the ticket. On: when that finds none, the ticket's text is sent to the Claude API with the names of the space's repositories. Either way, when it stays unclear the card asks you to pick one. Needs the API key in the AI tab.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Code review sessions") {
                TextEditor(text: $store.codeReviewPrompt)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90, maxHeight: 200)
                Text("The first message of a session started with Tasks, Review a Pull Request. Leave empty for the standard one, which starts with “\(CodeReview.standardCommand)”. " + CodeReview.placeholderHelp + " A space can have its own (Edit space).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Review") {
                if !ClaudeCode.isInstalled {
                    Text("The review asks Claude through Claude Code, which was not found on this Mac. Without it the review lists only what the app's own rules find.")
                        .foregroundStyle(.secondary)
                }
                TextField("Claude home", text: $store.reviewHome, prompt: Text("~/.claude (default)"))
                if !store.reviewHome.trimmingCharacters(in: .whitespaces).isEmpty,
                   Orca.resolvedHome(store.reviewHome) == nil {
                    Text("That is not a directory on this Mac.").font(.caption).foregroundStyle(.orange)
                }
                Picker("Model", selection: $store.reviewModel) {
                    ForEach(ClaudeCode.models, id: \.id) { Text($0.label).tag($0.id) }
                }
                Toggle("Review when a session stops", isOn: $store.reviewWhenSessionStops)
                Text("The review in the overview goes over every open task and its agent sessions and lists what needs you. It runs when you ask for it; with the switch on, also when an agent stops, at most every ten minutes. It changes nothing in Orca, the trackers or GitHub.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("It uses the login of this one Claude home for every space, not the API key: the requests count against that login's usage limits, the same ones its sessions use. Each space sets how much of it is sent (Edit space, Review); a new space sends its status only. Lines that look like keys or passwords are left out of agent and terminal text, which lowers the risk of sending a secret but does not remove it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: store.reviewHome) { store.save() }
        .onChange(of: store.reviewModel) { store.save() }
        .onChange(of: store.reviewWhenSessionStops) { store.save() }
        .onChange(of: store.agentQueueLimit) { store.save() }
        .onChange(of: store.codeReviewPrompt) { store.save() }
        .onChange(of: store.agentQueueSkipPermissions) { store.save() }
        .onChange(of: store.agentQueueAskClaude) { store.save() }
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
                Text("Used by “Explain” in the ticket details. Stored in the macOS Keychain. The ticket's text is sent to the Claude API only when you click Explain, or by the agent queue if you turned that on in Agents.")
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
