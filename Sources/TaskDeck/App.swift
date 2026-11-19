import SwiftUI
import AppKit

@main
struct TaskDeckApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        Window("TaskDeck", id: "main") {
            BoardView()
                .environment(store)
                .tint(Theme.accent)
                .frame(minWidth: 920, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 720)
        .commands { AppCommands(store: store) }

        MenuBarExtra {
            MenuBarView()
                .environment(store)
                .tint(Theme.accent)
        } label: {
            MenuBarLabel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
                .tint(Theme.accent)
        }
    }
}

struct MenuBarLabel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let running = store.runningTasks
        HStack(spacing: 4) {
            // A marked clock while it looks like work is going on with nothing tracked.
            Image(systemName: !running.isEmpty ? "record.circle" : store.forgotTimer ? "clock.badge.exclamationmark" : "timer")
            if running.count == 1, let task = running.first {
                // This sitting, like the card's clock and the Dock badge; not the task's whole time.
                Text("\(task.displayRef) \(Fmt.hm(task.currentStretch(now: store.now)))".trimmingCharacters(in: .whitespaces))
                    .monospacedDigit()
            } else if running.count > 1 {
                Text("\(running.count) timers")
            }
        }
    }
}
