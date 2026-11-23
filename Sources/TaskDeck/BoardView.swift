import SwiftUI
import AppKit

struct BoardView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: UUID?
    /// The space last shown, so the board opens on it again.
    @AppStorage("boardSpace") private var savedSpace = ""
    @State private var editing: TaskItem?
    @State private var logging: TaskItem?
    @State private var details: TaskItem?
    @State private var showImport = false
    @State private var showArchive = false
    @State private var showToday = false
    @State private var showPending = false
    @State private var showWaiting = false
    /// The window's tab: "overview" (the first page), "board" or "goals". Remembered between launches.
    @AppStorage("mainTab") private var tab = "overview"
    /// The goal open in the Goals tab, by id.
    @AppStorage("goalSelected") private var goalSelected = ""
    @State private var search = ""
    /// Not kept between launches: a board that opens with cards missing looks broken.
    @State private var filters: Set<BoardFilter> = []
    @FocusState private var searching: Bool
    /// The card the keyboard acts on. Nil until an arrow key or a click picks one.
    @State private var selected: UUID?
    @State private var deleting: TaskItem?
    @State private var startingSession: TaskItem?

    /// Every word typed has to appear somewhere in the task, in any order, ignoring case and accents.
    private func matches(_ task: TaskItem) -> Bool {
        // Ticked filters add up: a card shows when any of them fits, so "working" and "your turn"
        // together give every card with an agent that is doing or waiting for something.
        guard filters.isEmpty || filters.contains(where: { fits(task, $0) }) else { return false }
        let words = search.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = [task.title, task.displayRef, task.ref, task.notes, task.remoteStatus ?? "", task.remoteType ?? "",
                    task.estimateGap != nil ? "no estimate" : "",
                    task.due.map { "due " + Due.label($0) + (Due.daysLeft($0) < 0 ? " overdue" : "") } ?? "",
                    task.remoteAssignee ?? "", store.project(task.projectId)?.name ?? ""]
            .joined(separator: "\n")
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

private func fits(_ task: TaskItem, _ filter: BoardFilter) -> Bool {
        func session(_ kind: Orca.Status.Kind) -> Bool {
            store.sessions(of: task).contains { store.status(of: $0)?.kind == kind }
        }
        switch filter {
        case .timer: return task.isRunning
        case .working: return session(.working)
        case .yourTurn: return session(.yourTurn)
        case .prOpen: return session(.prOpen)
        case .session: return !store.sessions(of: task).isEmpty
        case .noEstimate: return task.estimateGap != nil
        // Finished work is not due any more, whatever its date says.
        case .due: return store.role(of: task.status) != .done && task.due.map { Due.daysLeft($0) <= 7 } == true
        }
    }

    /// How many cards on the board, in the current space, a filter would show.
    private func count(_ filter: BoardFilter) -> Int {
        store.columns.reduce(0) { $0 + store.tasks(in: $1.id, project: self.filter).filter { fits($0, filter) }.count }
    }

    private var filterMenu: some View {
        Menu {
            ForEach(BoardFilter.allCases) { item in
                let n = count(item)
                Toggle(n == 0 ? item.label : "\(item.label) (\(n))", isOn: Binding(
                    get: { filters.contains(item) },
                    set: { on in if on { filters.insert(item) } else { filters.remove(item) } }))
            }
            Divider()
            Button("Show All Cards") { filters = [] }.disabled(filters.isEmpty)
        } label: {
            Image(systemName: filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(filters.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(filters.isEmpty ? "Filter the board"
              : "Showing only: " + BoardFilter.allCases.filter(filters.contains).map(\.label).joined(separator: ", "))
    }

    /// Goes to where a waiting thing is dealt with: the session in Orca, the list of assigned
    /// tickets, or the card on the board (found by searching for it).
    private func open(_ item: AppStore.WaitingItem) {
        if item.kind == .assigned { showImport = true; return }
        if let session = item.session, item.kind == .yourTurn {
            Task { await Orca.reveal(session) }
            return
        }
        guard let task = item.task else { return }
        tab = "board"
        if filter != nil, filter != task.projectId { filter = task.projectId }
        search = task.ref.isEmpty ? task.title : task.ref
    }

    // MARK: Keyboard

    /// The cards on screen, lane by lane, as filtered by space and search.
    private var lanes: [(column: BoardColumn, tasks: [TaskItem])] {
        store.columns.map { ($0, store.tasks(in: $0.id, project: filter).filter(matches)) }
    }

    private func openCard(_ task: TaskItem) {
        // Without an integration there are no details to fetch: open the editor.
        if TicketFetcher.canFetch(project: store.project(task.projectId), task: task) { details = task } else { editing = task }
    }

    /// Handles a key pressed in the main window while no text is being typed. True when used.
    private func key(_ event: NSEvent, inSearch: Bool) -> Bool {
        guard tab == "board" else { return false }
        let lanes = lanes
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let first = lanes.first { !$0.tasks.isEmpty }?.tasks.first
        if inSearch {
            // Down, Return or Tab leaves the field for the first card found.
            guard flags.isEmpty, [125, 36, 48].contains(event.keyCode), let first else { return false }
            event.window?.makeFirstResponder(nil)
            selected = first.id
            return true
        }
        var lane = 0, row = 0, current: TaskItem?
        for (l, entry) in lanes.enumerated() {
            if let r = entry.tasks.firstIndex(where: { $0.id == selected }) { lane = l; row = r; current = entry.tasks[r] }
        }
        let arrows: Set<UInt16> = [123, 124, 125, 126, 48]
        guard let task = current else {
            // Nothing picked yet: any arrow, or Tab, starts at the first card.
            guard flags.isEmpty || flags == .shift, arrows.contains(event.keyCode), let first else { return false }
            selected = first.id
            return true
        }
        let cards = lanes[lane].tasks
        // Tab goes lane by lane, to the top card, and round again at the end. macOS itself only
        // moves Tab between text fields, and the board has none.
        if event.keyCode == 48, flags.isEmpty || flags == .shift {
            let step = flags == .shift ? -1 : 1
            var l = lane
            repeat { l = (l + step + lanes.count) % lanes.count } while lanes[l].tasks.isEmpty && l != lane
            if let top = lanes[l].tasks.first { selected = top.id }
            return true
        }
        if flags == .command {
            switch event.keyCode {
            case 126: if row > 0 { store.place(task.id, before: cards[row - 1].id, in: task.status) }
            case 125: if row < cards.count - 1 {
                store.place(task.id, before: row + 2 < cards.count ? cards[row + 2].id : nil, in: task.status)
            }
            case 123: if lane > 0 { store.move(task.id, to: lanes[lane - 1].column.id) }
            case 124: if lane < lanes.count - 1 { store.move(task.id, to: lanes[lane + 1].column.id) }
            default: return false
            }
            return true
        }
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 126: if row > 0 { selected = cards[row - 1].id }
        case 125: if row < cards.count - 1 { selected = cards[row + 1].id }
        case 123, 124:
            // The nearest lane that way with a card in it, at the same height when it has one.
            let step = event.keyCode == 123 ? -1 : 1
            var l = lane + step
            while l >= 0, l < lanes.count, lanes[l].tasks.isEmpty { l += step }
            if l >= 0, l < lanes.count { selected = lanes[l].tasks[min(row, lanes[l].tasks.count - 1)].id }
        case 36, 76: openCard(task)
        case 49: store.toggleTimer(task.id)
        case 53: selected = nil
        case 51, 117: deleting = task
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "e": editing = task
            case "o":
                guard let url = URL(string: task.url), !task.url.isEmpty else { return false }
                Browser.open(url, space: store.project(task.projectId))
            case "l":
                guard store.project(task.projectId)?.kind == .redmine else { return false }
                logging = task
            case "s":
                guard Orca.isInstalled else { return false }
                startingSession = task
            case "c":
                guard !task.url.isEmpty else { return false }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.url, forType: .string)
            default: return false
            }
        }
        return true
    }

    private func focusSearch() {
        searching = true
        focusToolbarSearch(placeholder: "Search tasks")
    }

    private func newTask() {
        newTask(goal: tab == "goals" ? UUID(uuidString: goalSelected).flatMap { store.goal($0)?.id } : nil)
    }

    private func newTask(goal: UUID?) {
        var task = TaskItem(projectId: filter ?? store.projects.first?.id, status: store.defaultColumnId)
        task.goalId = goal
        editing = task
    }

    /// Tracked time that is not on Redmine yet, in minutes worth showing.
    private var pendingSeconds: TimeInterval {
        let pending = store.pendingLogTasks.reduce(0) { $0 + $1.unloggedSeconds }
        return pending >= 60 ? pending : 0
    }

    /// "Time to push": a pale orange button of its own before the gray group, there only while there is
    /// time to log. The toolbar item itself always exists; its content comes and goes.
    @ToolbarContentBuilder
    private var pendingItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                if pendingSeconds > 0 {
                    Button { showPending = true } label: {
                        // Drawn by hand, like "New task": a tinted button style in the toolbar comes out oversized.
                        pendingLabel
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .glassEffect(.regular.tint(Theme.pending).interactive(), in: .capsule)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Time to push: tracked time that is not on Redmine yet (⌘L)")
                }
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                if pendingSeconds > 0 {
                    Button { showPending = true } label: { pendingLabel }
                        .help("Time to push: tracked time that is not on Redmine yet (⌘L)")
                        .buttonStyle(.borderedProminent).tint(Theme.pending)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var searchGap: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }

    private var pendingLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.circle").font(.system(size: 14, weight: .semibold))
            Text(Fmt.short(pendingSeconds)).monospacedDigit().fontWeight(.semibold)
        }
        // Orange on the pale fill, exactly like the not-logged chip on a card.
        .foregroundStyle(Color.orange)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time to push: \(Fmt.short(pendingSeconds))")
    }

    /// "New task": a red circle of its own, apart from the gray toolbar group.
    @ToolbarContentBuilder
    private var newTaskItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button(action: newTask) {
                    // Drawn by hand: a tinted button style in the toolbar comes out oversized and not round.
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .circle)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New task")
                .help("New task (⌘N)")
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button(action: newTask) { Label("New task", systemImage: "plus") }
                    .help("New task (⌘N)")
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
    }

        var body: some View {
        @Bindable var store = store
        Group {
            if tab == "overview" {
                OverviewView(spaceId: filter, onDetails: { details = $0 })
            } else if tab == "goals" {
                GoalsView(spaceId: filter, selection: $goalSelected, onOpen: openCard, onNewTask: { newTask(goal: $0) })
            } else {
                GeometryReader { geo in
                    // Columns share the window width; with many columns they keep a readable width and scroll sideways.
                    let count = CGFloat(max(store.columns.count, 1))
                    let width = max(250, (geo.size.width - 24 - 12 * (count - 1)) / count)
                    ScrollViewReader { sideways in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(store.columns) { column in
                                ColumnView(
                                    column: column,
                                    tasks: store.tasks(in: column.id, project: filter).filter(matches),
                                    selected: selected,
                                    onSelect: { selected = $0.id },
                                    onEdit: { editing = $0 },
                                    onLog: { logging = $0 },
                                    onDetails: { details = $0 },
                                    onShowArchive: { showArchive = true }
                                )
                                .frame(width: width)
                                .id(column.id)
                            }
                        }
                        .padding(12)
                        .frame(height: geo.size.height)
                    }
                    // With many lanes the picked card's lane may be off to the side.
                    .onChange(of: selected) { _, new in
                        if let column = store.tasks.first(where: { $0.id == new })?.status {
                            withAnimation(.easeOut(duration: 0.15)) { sideways.scrollTo(column) }
                        }
                    }
                    }
                }
                .background(KeyCatcher(handler: key))
                .sheet(item: $startingSession) { task in
                    StartSessionView(taskId: task.id, detail: TicketCache.load(task.id)?.detail).environment(store)
                }
                .confirmationDialog("Delete “\(deleting.map { $0.title.isEmpty ? $0.displayRef : $0.title } ?? "")”?",
                                    isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                    Button("Delete task", role: .destructive) {
                        if let id = deleting?.id { store.delete(task: id) }
                        deleting = nil
                    }
                    Button("Cancel", role: .cancel) { deleting = nil }
                } message: {
                    Text("Its tracked time is deleted too. This cannot be undone.")
                }
            }
        }
        .overlay(alignment: .bottom) {
            BackdateBanner().frame(maxWidth: 520).padding(.bottom, 16)
                .animation(.easeOut(duration: 0.2), value: store.backdateOffer)
        }
        // The menu bar carries the shortcuts, so each shows next to its command there.
        .focusedSceneValue(\.board, BoardActions(
            newTask: newTask,
            fetchAssigned: { showImport = true },
            logPending: pendingSeconds > 0 ? { showPending = true } : nil,
            showArchive: { showArchive = true },
            search: focusSearch,
            show: { tab = $0 },
            space: filter,
            showSpace: { filter = $0 }))
        .onAppear {
            // A space deleted since last time falls back to all spaces.
            if let id = UUID(uuidString: savedSpace), store.project(id) != nil { filter = id }
        }
        .onChange(of: filter) { _, new in savedSpace = new?.uuidString ?? "" }
        // The window keeps its name for Mission Control and the Window menu; the toolbar has no room for it.
        .modifier(NoToolbarTitle())
        // The results are cards, so typing a search from another tab moves to the board.
        .onChange(of: search) { _, new in
            if !new.trimmingCharacters(in: .whitespaces).isEmpty, tab != "board" { tab = "board" }
        }
        .onChange(of: filters) { _, new in
            if !new.isEmpty, tab == "overview" { tab = "board" }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Space", selection: $filter) {
                    Text("All spaces").tag(UUID?.none)
                    ForEach(store.projects) { p in
                        Text(p.name).tag(UUID?.some(p.id))
                    }
                }
                .fixedSize()
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    Text("Overview").tag("overview")
                    Text("Board").tag("board")
                    Text("Goals").tag("goals")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Overview (⌘1), board (⌘2) or goals (⌘3) of \(store.project(filter)?.name ?? "all spaces")")
            }
            ToolbarItem(placement: .navigation) {
                // With "All spaces", a click shows today's time per space.
                Button { if filter == nil { showToday.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                        Text("Today: \(Fmt.short(store.trackedToday(now: store.now, project: filter)))")
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                }
                .help(filter == nil ? "Show today's time per space" : "Time tracked today in this space")
                .popover(isPresented: $showToday, arrowEdge: .bottom) {
                    TodayBreakdown().environment(store)
                }
            }
            // A field of its own instead of the system search item: that one always sits last in the
            // toolbar and takes all the room left, and this one goes before the buttons at a fixed width.
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search tasks", text: $search)
                        .textFieldStyle(.plain)
                        .focused($searching)
                        .onExitCommand {
                            search = ""
                            searching = false
                        }
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Clear the search")
                    }
                    filterMenu
                }
                .padding(.horizontal, 10)
                .frame(width: 210)
            }
            // Keeps the search field a pill of its own. Without it the buttons that follow share
            // its glass whenever there is no time-to-push button in between.
            searchGap
            pendingItem
            ToolbarItemGroup(placement: .primaryAction) {
                let waiting = store.waitingItems.count
                Button { showWaiting.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: waiting == 0 ? "bell" : "bell.badge")
                        if waiting > 0 { Text("\(waiting)").monospacedDigit() }
                    }
                }
                .help(waiting == 0 ? "Nothing is waiting for you" : "Waiting for you: \(waiting)")
                .popover(isPresented: $showWaiting, arrowEdge: .bottom) {
                    WaitingList { item in
                        showWaiting = false
                        open(item)
                    }
                    .environment(store)
                }
                // Refresh has no button: it is Tasks → Refresh (⌘R), and runs by itself every 15 minutes.
                Button { showImport = true } label: {
                    Label("Assigned to me", systemImage: "tray.and.arrow.down")
                }
                .help("Fetch tickets assigned to me (⌘I)")
            }
            newTaskItem
        }
        .onChange(of: store.singleTimer) { store.save() }
        .sheet(item: $editing) { task in
            TaskEditor(task: task).environment(store)
        }
        .sheet(item: $logging) { task in
            LogTimeView(taskId: task.id).environment(store)
        }
        .sheet(item: $details) { task in
            IssueDetailView(taskId: task.id).environment(store)
        }
        .sheet(isPresented: $showArchive) {
            ArchiveView().environment(store)
        }
        .sheet(isPresented: $showPending) {
            PendingTimeView().environment(store)
        }
        .sheet(isPresented: $showImport) {
            ImportView().environment(store)
        }
    }
}

/// A session's badges: its pull request, when it has one, and the session itself. Two badges so
/// both stay one click away: the pull request opens on GitHub, the session in Orca.
struct SessionBadges: View {
    let session: AgentSession
    let status: Orca.Status?
    let space: Project?
    let count: Int
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            if let status, let pr = status.prURL {
                Button { Browser.open(pr, space: space) } label: {
                    PullRequestBadge(status: status, compact: compact).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(status.isAboutPullRequest ? status.detail : "A pull request is open for this worktree.") Click to open it.")
            }
            Button { Task { await Orca.reveal(session) } } label: {
                SessionBadge(status: status, count: count, compact: compact, agentOnly: status?.prURL != nil)
                    .fixedSize()
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Agent session “\(session.name)” in \(session.repoName). \(status?.isAboutPullRequest == true ? "" : status?.detail ?? "") Click to open it in Orca.")
        }
    }
}

/// The quick filters beside the search field.
enum BoardFilter: String, CaseIterable, Identifiable {
    case timer, working, yourTurn, prOpen, session, noEstimate, due
    var id: String { rawValue }
    var label: String {
        switch self {
        case .timer: return "Timer running"
        case .working: return "Agent working"
        case .yourTurn: return "Your turn"
        case .prOpen: return "Pull request open"
        case .session: return "Has an agent session"
        case .noEstimate: return "No estimate"
        case .due: return "Due within a week or overdue"
        }
    }
}

/// Hides the window's name in the toolbar. Before macOS 15 it stays.
private struct NoToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// What the main window offers to the menu bar. Nil while another window is in front.
/// What the Dock badge counts, one line each. A click goes to where the thing is dealt with.
private struct WaitingList: View {
    @Environment(AppStore.self) private var store
    let open: (AppStore.WaitingItem) -> Void

    var body: some View {
        let items = store.waitingItems
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Waiting for you").font(.headline)
                Spacer()
                if !items.isEmpty {
                    Button("Clear all") { store.clearWaiting(items.map(\.id)) }
                        .buttonStyle(.borderless).font(.callout)
                        .help("Take everything off this list. Each item comes back if it happens again.")
                }
            }
            if items.isEmpty {
                Text("Nothing is waiting for you.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in
                            HStack(spacing: 4) {
                                Button { open(item) } label: { row(item) }.buttonStyle(.plain)
                                Button { store.clearWaiting([item.id]) } label: {
                                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, height: 20).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Clear this one. It comes back if it happens again.")
                            }
                        }
                    }
                }
                // A scroll view has no height of its own in a popover.
                .frame(height: min(360, CGFloat(items.count) * 44))
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func row(_ item: AppStore.WaitingItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(item.kind)).foregroundStyle(color(item.kind)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                if let task = item.task {
                    Text("\(task.displayRef) \(task.title)".trimmingCharacters(in: .whitespaces)).lineLimit(1)
                } else if let title = item.title {
                    Text(title).lineLimit(1)
                }
                let alone = item.task == nil && item.title == nil
                Text(item.detail).font(alone ? .body : .caption)
                    .foregroundStyle(alone ? .primary : .secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 40)
        .contentShape(Rectangle())
        .help(item.detail)
    }

    private func icon(_ kind: AppStore.WaitingItem.Kind) -> String {
        switch kind {
        case .yourTurn: return "bubble.left.fill"
        case .pullRequest: return "arrow.triangle.pull"
        case .repository: return "questionmark.folder"
        case .notStarted: return "exclamationmark.triangle.fill"
        case .assigned: return "tray.and.arrow.down"
        }
    }

    private func color(_ kind: AppStore.WaitingItem.Kind) -> Color {
        switch kind {
        case .yourTurn, .repository: return .orange
        case .notStarted: return .red
        case .pullRequest, .assigned: return .secondary
        }
    }
}

/// Finds the toolbar's search field in the window and gives it the keyboard. Focus state alone
/// does not do it: a toolbar item is hosted outside the view that owns the state, so setting
/// it from a menu command is not reliably carried over.
@MainActor
func focusToolbarSearch(placeholder: String) {
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
    func find(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.placeholderString == placeholder { return field }
        for child in view.subviews {
            if let found = find(child) { return found }
        }
        return nil
    }
    // The toolbar lives in the window's frame view, beside the content view rather than in it.
    let roots = [window.contentView?.superview].compactMap { $0 } + (window.toolbar?.items.compactMap(\.view) ?? [])
    for root in roots {
        if let field = find(root) {
            window.makeFirstResponder(field)
            // Like Find elsewhere: what is already typed is selected, ready to be replaced.
            field.currentEditor()?.selectAll(nil)
            return
        }
    }
}

/// Passes key presses in its window to a view. A window-level watch rather than SwiftUI focus:
/// a board or a list of rows is not a control, and focus does not settle on it reliably. Keys
/// typed into a text field are left alone, except in the one field named, which may hand over.
struct KeyCatcher: NSViewRepresentable {
    /// Placeholder of the text field whose keys are passed on too (with `inField` true).
    var field: String? = "Search tasks"
    /// True when the key was used and should go no further.
    let handler: (NSEvent, _ inField: Bool) -> Bool

    final class Coordinator {
        var handler: (NSEvent, Bool) -> Bool = { _, _ in false }
        weak var view: NSView?
        var monitor: Any?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        let fieldName = field
        coordinator.view = view
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only the board's own window, and not while a sheet covers it.
            guard let window = coordinator.view?.window, event.window === window, window.attachedSheet == nil else { return event }
            var inSearch = false
            if let editor = window.firstResponder as? NSText {
                guard let field = editor.delegate as? NSTextField, fieldName != nil, field.placeholderString == fieldName else { return event }
                inSearch = true
            }
            return coordinator.handler(event, inSearch) ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Refreshed on every pass, so the handler always sees the board as it is now.
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
}

struct BoardActions {
    var newTask: () -> Void
    var fetchAssigned: () -> Void
    /// Nil when there is no time waiting to be logged.
    var logPending: (() -> Void)?
    var showArchive: () -> Void
    var search: () -> Void
    /// "overview", "board" or "goals".
    var show: (String) -> Void
    /// The space shown, nil for all spaces.
    var space: UUID?
    var showSpace: (UUID?) -> Void
}

private struct BoardActionsKey: FocusedValueKey {
    typealias Value = BoardActions
}

extension FocusedValues {
    var board: BoardActions? {
        get { self[BoardActionsKey.self] }
        set { self[BoardActionsKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    let store: AppStore
    @FocusedValue(\.board) private var board

    var body: some Commands {
        // The app has one window, so "New" means a task.
        CommandGroup(replacing: .newItem) {
            Button("New Task") { board?.newTask() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(board == nil)
        }
        CommandMenu("Tasks") {
            Button("Fetch Tickets Assigned to Me…") { board?.fetchAssigned() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(board == nil)
            Button("Log Pending Time…") { board?.logPending?() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(board?.logPending == nil)
            Button("Refresh") { Task { await store.refreshEverything() } }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Stop All Timers") { store.stopAll() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("Show Archive") { board?.showArchive() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(board == nil)
        }
        CommandGroup(before: .toolbar) {
            Button("Overview") { board?.show("overview") }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(board == nil)
            Button("Board") { board?.show("board") }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(board == nil)
            Button("Goals") { board?.show("goals") }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(board == nil)
            Divider()
            Button("Search Tasks") { board?.search() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(board == nil)
            Divider()
            // Toggles, so the space being shown carries a checkmark.
            Toggle("All Spaces", isOn: Binding(get: { board != nil && board?.space == nil },
                                               set: { _ in board?.showSpace(nil) }))
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(board == nil)
            ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, space in
                let toggle = Toggle(space.name, isOn: Binding(get: { board?.space == space.id },
                                                              set: { _ in board?.showSpace(space.id) }))
                    .disabled(board == nil)
                // Only the first nine get a number key.
                if index < 9 {
                    toggle.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                } else {
                    toggle
                }
            }
            Divider()
        }
    }
}

/// Where a task stands in the agent queue: waiting its turn, waiting for the user to pick a
/// repository, or stopped by an error.
private struct QueueBadge: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    @State private var picking = false

    var body: some View {
        if task.queueNote == TaskItem.needsRepository {
            Button { picking = true } label: {
                chip("Pick repository", icon: "questionmark.folder", color: .orange)
            }
            .buttonStyle(.plain)
            .help("The ticket does not say which repository it is about. Click to choose one; the agent starts after that.")
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                QueueRepositoryPicker(task: task) { picking = false }.environment(store)
            }
        } else if let note = task.queueNote {
            Button { store.retryQueued(task.id) } label: {
                chip("Not started", icon: "exclamationmark.triangle", color: .red)
            }
            .buttonStyle(.plain)
            .help("\(note) Click to try again.")
        } else if (task.sessions ?? []).contains(where: { $0.queued == true }) {
            // Started; the session badge next to this one says how it is going.
            EmptyView()
        } else {
            chip("Queued", icon: "hourglass", color: .secondary)
                .help("Waiting for a free slot. Up to \(store.agentQueueLimit) queued sessions work at once.")
        }
    }

    private func chip(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).font(.caption.weight(.medium))
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
        .contentShape(Capsule())
    }
}

/// Asks which repository a queued task belongs in: the space's own first, then the rest.
private struct QueueRepositoryPicker: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    let done: () -> Void
    @State private var repos: [Orca.Repo] = []
    @State private var failure: String?
    @State private var loaded = false

    var body: some View {
        let project = store.project(task.projectId)
        let own = repos.filter { project?.owns($0) ?? false }
        let others = repos.filter { !(project?.owns($0) ?? false) }
        VStack(alignment: .leading, spacing: 8) {
            Text("Repository for \(task.displayRef.isEmpty ? "this task" : task.displayRef)").font(.headline)
            if let failure {
                Text(failure).font(.callout).foregroundStyle(.red)
            } else if !loaded {
                ProgressView().controlSize(.small)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if !own.isEmpty {
                            Text(project?.name ?? "This space").font(.caption).foregroundStyle(.secondary)
                            ForEach(own) { row($0) }
                        }
                        if !others.isEmpty {
                            Text(own.isEmpty ? "Repositories" : "Other repositories")
                                .font(.caption).foregroundStyle(.secondary).padding(.top, own.isEmpty ? 0 : 6)
                            ForEach(others) { row($0) }
                        }
                    }
                }
                // A scroll view has no height of its own in a popover and collapsed to one line,
                // hiding every row; give it the height of its rows, up to a limit.
                .frame(height: min(280, CGFloat(repos.count) * 24 + 44))
            }
        }
        .padding(14)
        .frame(width: 300)
        .task {
            do { repos = try await Orca.repos() } catch { failure = error.localizedDescription }
            loaded = true
        }
    }

    private func row(_ repo: Orca.Repo) -> some View {
        Button {
            store.setQueueRepository(repo.id, for: task.id)
            done()
        } label: {
            Text(repo.name).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}

struct ColumnView: View {
    @Environment(AppStore.self) private var store
    let column: BoardColumn
    let tasks: [TaskItem]
    var selected: UUID? = nil
    var onSelect: (TaskItem) -> Void = { _ in }
    let onEdit: (TaskItem) -> Void
    let onLog: (TaskItem) -> Void
    let onDetails: (TaskItem) -> Void
    let onShowArchive: () -> Void
    @State private var targeted = false
    /// The card a dragged task would be placed above, while one is held over it.
    @State private var dropAbove: UUID?
    @State private var dropAtEnd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(column.displayName).font(.headline).lineLimit(1)
                Text("\(tasks.count)")
                    .font(.caption).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
                if column.role == .done && !tasks.isEmpty {
                    Button("Archive") { store.archive(column: column.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Removes done tasks from the board (time history is kept)")
                }
                if column.role == .done && store.archivedCount > 0 {
                    Button(action: onShowArchive) {
                        Label("\(store.archivedCount)", systemImage: "archivebox")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Show archived tasks")
                }
            }
            .padding(.horizontal, 4)

            ScrollViewReader { lane in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tasks) { task in
                        TaskCard(task: task, selected: selected == task.id, onSelect: { onSelect(task) },
                                 onEdit: { onEdit(task) }, onLog: { onLog(task) }, onDetails: { onDetails(task) })
                            // A line in the gap above the card shows where the dragged one lands.
                            .overlay(alignment: .top) {
                                if dropAbove == task.id {
                                    Capsule().fill(Theme.accent).frame(height: 3).offset(y: -5.5)
                                }
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                                store.place(id, before: task.id, in: column.id)
                                return true
                            } isTargeted: { over in
                                if over { dropAbove = task.id } else if dropAbove == task.id { dropAbove = nil }
                            }
                    }
                    // Room under the last card to drop a task at the end of the lane.
                    Color.clear
                        .frame(height: 44)
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) {
                            if dropAtEnd { Capsule().fill(Theme.accent).frame(height: 3).offset(y: -5.5) }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                            store.place(id, before: nil, in: column.id)
                            return true
                        } isTargeted: { dropAtEnd = $0 }
                }
                .padding(.bottom, 8)
                .animation(.easeOut(duration: 0.15), value: tasks.map(\.id))
            }
            // Keeps the card picked with the keyboard in view in a long lane.
            .onChange(of: selected) { _, new in
                if let new, tasks.contains(where: { $0.id == new }) {
                    withAnimation(.easeOut(duration: 0.15)) { lane.scrollTo(new) }
                }
            }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Radius.column, style: .continuous)
                .fill(Color.primary.opacity(targeted ? 0.10 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.column, style: .continuous)
                .strokeBorder(Theme.accent.opacity(targeted ? 0.8 : 0), lineWidth: 2)
        )
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
            store.move(id, to: column.id)
            return true
        } isTargeted: { targeted = $0 }
    }
}

struct TaskCard: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    var selected = false
    var onSelect: () -> Void = {}
    let onEdit: () -> Void
    let onLog: () -> Void
    let onDetails: () -> Void
    @State private var hovering = false
    @State private var confirmDelete = false
    @State private var startingSession = false
    @State private var creatingTicket = false
    @State private var pickingDue = false

    /// Pills only: what needs doing on the left, the timer on the right. `level` is how hard the row
    /// is squeezed to fit the lane: 0 everything in words, 1 the session badge as an icon, 2 the
    /// due date as an icon too, 3 the time not logged as an icon as well.
    private func footer(project: Project?, running: Bool, level: Int) -> some View {
        let compact = level >= 1
        return HStack(spacing: 6) {
            if project?.kind == .redmine, Int(task.ref) != nil, task.unloggedSeconds >= 60 {
                // A compact one-line chip: an "upload" arrow and the time not yet logged.
                Button(action: onLog) {
                    if level >= 3 {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.orange)
                            .frame(width: 20, height: 20)
                            .background(Color.orange.opacity(0.15), in: Circle())
                            .contentShape(Circle())
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 9, weight: .bold))
                            Text(Fmt.short(task.unloggedSeconds))
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                        }
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(Color.orange)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .contentShape(Capsule())
                    }
                }
                .buttonStyle(.plain)
                .help("\(Fmt.short(task.unloggedSeconds)) not logged yet — click to log it to Redmine")
            }
            if let due = task.due, store.role(of: task.status) != .done {
                Button { pickingDue = true } label: { DueChip(date: due, compact: level >= 2) }
                    .buttonStyle(.plain)
                    .help(Due.help(task) + " — click to change")
            }
            // Not on finished work: an estimate nobody set no longer needs setting.
            if let gap = task.estimateGap, store.role(of: task.status) != .done {
                Image(systemName: "hourglass")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 20, height: 20)
                    .background(Color.orange.opacity(0.15), in: Circle())
                    .help("\(gap) not set in Redmine. Set it in the ticket details.")
            }
            if store.role(of: task.status) == .agents {
                QueueBadge(task: task)
            }
            if let session = store.headlineSession(of: task) {
                SessionBadges(session: session, status: store.status(of: session), space: project,
                              count: store.sessions(of: task).count, compact: compact)
            }
            Spacer(minLength: 0)
            Button {
                store.toggleTimer(task.id)
            } label: {
                if running {
                    // The clock sits in the button that stops it. It counts this sitting only; the
                    // task's whole time is in the top row.
                    HStack(spacing: 4) {
                        Text(Fmt.clock(task.currentStretch(now: store.now)))
                            .font(.caption.weight(.semibold)).monospacedDigit()
                        Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold))
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(Theme.accent, in: Capsule())
                    .contentShape(Capsule())
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                        Text("Start").font(.caption.weight(.medium))
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(Theme.accent)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .help(running ? "This sitting, since the timer was started. Click to pause." : "Start timer")
            // The running clock always shows, so it can always be stopped.
            .opacity(hovering || running ? 1 : 0)
        }
    }

    /// Up to two letters for a person: "luiz.v" is LV, "Geiser Menoia" is GM.
    private func initials(_ name: String) -> String {
        let words = name.split { " ._-@".contains($0) }.prefix(2)
        return words.compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    private func header(project: Project?, running: Bool, type showType: Bool, total showTotal: Bool) -> some View {
        HStack(spacing: 6) {
            // The project is shown by the colour strip on the card's left edge.
            if !task.displayRef.isEmpty {
                if let url = URL(string: task.url), !task.url.isEmpty {
                    TicketLink(text: task.displayRef, url: url, space: project)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .fixedSize()
                        .help(task.url)
                } else {
                    Text(task.displayRef).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            } else {
                // A task without a ticket has nothing to put here, which left the row looking
                // broken. Saying so fills the place the reference would, in the same colour.
                Text("No ticket")
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .fixedSize()
            }
            if showType, let type = task.remoteType, !type.isEmpty {
                // Plain text, not a second pill: two pills side by side read as two statuses.
                Text(type)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help("Type in \(project?.kind.label ?? "the tracker")")
            }
            Spacer(minLength: 0)
            // The task's whole time lives here, apart from the pills below. While a timer runs it
            // shows only with earlier time: otherwise the clock below already is the total.
            if showTotal, running ? task.total(now: store.now) - task.currentStretch(now: store.now) >= 60
                                  : task.total(now: Date()) >= 60 {
                Text(Fmt.short(task.total(now: running ? store.now : Date())))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help("All time tracked on this task, this sitting included")
            }
            if let status = task.remoteStatus, !status.isEmpty {
                // The one thing in this row that may be cut short; the rest keeps its width.
                Text(status.prefix(1).uppercased() + status.dropFirst())
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                    .layoutPriority(-1)
                    .help("\(status) in \(project?.kind.label ?? "the tracker")")
            }
            // Initials, not the name: a name never fitted beside the rest and was cut to a letter
            // or two anyway. The full name is in the tooltip and in the ticket details.
            if let assignee = task.remoteAssignee, !assignee.isEmpty {
                Text(initials(assignee))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.quaternary, in: Circle())
                    .help("Assigned to \(assignee) in \(project?.kind.label ?? "the tracker")")
            }
        }
    }

    var body: some View {
        let project = store.project(task.projectId)
        let running = task.isRunning
        VStack(alignment: .leading, spacing: 6) {
            // The whole row when it fits; in a narrow column the type goes first, then the total.
            // A row wider than the card is not cut off but pushes the card out of its column.
            ViewThatFits(in: .horizontal) {
                header(project: project, running: running, type: true, total: true)
                header(project: project, running: running, type: false, total: true)
                header(project: project, running: running, type: false, total: false)
            }

            Text(task.title.isEmpty ? "(untitled)" : task.title)
                .font(.body)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label {
                    Text(task.notes.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "note.text")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(task.notes)
            }

            // The full row when it fits; in a narrow column the session badge shrinks to its icon.
            // A row wider than the card is not cut off but pushes the card out of its column.
            ViewThatFits(in: .horizontal) {
                footer(project: project, running: running, level: 0)
                footer(project: project, running: running, level: 1)
                footer(project: project, running: running, level: 2)
                footer(project: project, running: running, level: 3)
            }
        }
        .padding(10)
        // No edit button on the card: it covered the assignee. Edit is in the right-click menu (and E).
        // Running timer: a faint red wash over the card.
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(Theme.accent.opacity(running ? 0.13 : 0)))
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
        )
        // A strip in the project's colour down the left edge, cut to the card's rounded corners.
        .overlay(alignment: .leading) {
            if let project {
                Rectangle().fill(project.color).frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture(count: 2) {
            // Without an integration there are no details to fetch: open the editor.
            if TicketFetcher.canFetch(project: project, task: task) { onDetails() } else { onEdit() }
        }
        // After the double-click, so that one is recognised first. A click picks the card for the keyboard.
        .onTapGesture { onSelect() }
        .help(TicketFetcher.canFetch(project: project, task: task) ? "Double-click to see ticket details" : "Double-click to edit")
        .draggable(task.id.uuidString)
        .contextMenu {
            let link = task.url.isEmpty ? nil : URL(string: task.url)
            Button(running ? "Pause timer" : "Start timer") { store.toggleTimer(task.id) }
            // Only with something to log: otherwise the sheet opens empty.
            if project?.kind == .redmine, task.unloggedSeconds >= 60 {
                Button("Log time to Redmine…", action: onLog)
            }
            Divider()
            if TicketFetcher.canFetch(project: project, task: task) {
                Button("View ticket details…", action: onDetails)
            }
            if task.ref.isEmpty, let project, project.kind != .other {
                Button("Create in \(project.kind.label)…") { creatingTicket = true }
            }
            if let link {
                Button("Open ticket in browser") { Browser.open(link, space: project) }
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                }
            }
            Divider()
            Button("Start agent session…") { startingSession = true }
            if let session = store.headlineSession(of: task) {
                Button("Open session in Orca") { Task { await Orca.reveal(session) } }
            }
            if let pr = store.sessions(of: task).compactMap({ store.status(of: $0)?.prURL }).last {
                Button("Open pull request in browser") { Browser.open(pr, space: project) }
            }
            Divider()
            Menu("Move to") {
                Button("Top of this lane") { store.moveToTop(task.id) }
                Button("Bottom of this lane") { store.place(task.id, before: nil, in: task.status) }
                Divider()
                ForEach(store.columns.filter { $0.id != task.status }) { c in
                    Button(c.displayName) { store.move(task.id, to: c.id) }
                }
            }
            Divider()
            Menu("Due date") { DueMenuItems(task: task) { pickingDue = true } }
            Button("Edit…", action: onEdit)
            Button("Archive") { store.archive(task: task.id) }
            Button("Delete…", role: .destructive) { confirmDelete = true }
        }
        .sheet(isPresented: $creatingTicket) {
            CreateTicketView(taskId: task.id).environment(store)
        }
        .popover(isPresented: $pickingDue, arrowEdge: .trailing) {
            DuePicker(taskId: task.id).environment(store)
        }
        .sheet(isPresented: $startingSession) {
            // The ticket as last loaded in the details, when there is a copy: the prompt is
            // better with the description than with the title alone.
            StartSessionView(taskId: task.id, detail: TicketCache.load(task.id)?.detail).environment(store)
        }
        .confirmationDialog("Delete “\(task.title.isEmpty ? task.displayRef : task.title)”?", isPresented: $confirmDelete) {
            Button("Delete task", role: .destructive) {
                store.delete(task: task.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its tracked time is deleted too. This cannot be undone.")
        }
    }
}

/// Popover of the toolbar's "Today" total: time tracked today, per space.
struct TodayBreakdown: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let now = store.now
        let total = store.trackedToday(now: now)
        let rows = store.projects
            .map { (project: $0, seconds: store.trackedToday(now: now, project: $0.id)) }
            .filter { $0.seconds >= 1 }
            .sorted { $0.seconds > $1.seconds }
        let other = total - rows.reduce(0) { $0 + $1.seconds }
        VStack(alignment: .leading, spacing: 8) {
            Text("Today by space").font(.headline)
            if total < 1 {
                Text("No time tracked today.").foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.project.id) { row in
                line(row.project.name, row.seconds, color: row.project.color)
            }
            if other >= 1 { line("No space", other, color: .gray) }
            if total >= 1 {
                Divider()
                HStack {
                    Text("Total").fontWeight(.semibold)
                    Spacer(minLength: 24)
                    Text(Fmt.short(total)).monospacedDigit().fontWeight(.semibold)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 220)
    }

    private func line(_ name: String, _ seconds: TimeInterval, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name)
            Spacer(minLength: 24)
            Text(Fmt.short(seconds)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
