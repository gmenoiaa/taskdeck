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
            if store.forgotTimer && running.isEmpty {
                Image(systemName: "clock.badge.exclamationmark")
            } else {
                Image(nsImage: MenuBarIcon.image(running: !running.isEmpty))
            }
            if running.count == 1, let task = running.first {
                // This sitting, like the card's clock and the Dock badge; not the task's whole time.
                // No ticket number: it took room in a crowded menu bar, and the menu names the task.
                Text(Fmt.short(task.currentStretch(now: store.now)))
                    .monospacedDigit()
            } else if running.count > 1 {
                Text("\(running.count) timers")
            }
            // An agent of a task being timed stopped and waits: the reason to open the menu.
            if running.contains(where: { task in
                store.sessions(of: task).contains { store.status(of: $0)?.kind == .yourTurn }
            }) {
                Image(systemName: "bell.badge.fill")
            }
        }
    }
}

/// The app icon's front card, drawn as a template so macOS tints it like the other menu bar
/// items: a card with a play sign and two lines, another card behind it. While a
/// timer runs the play sign turns into a pause sign. Drawn in code: an asset catalog needs Xcode.
enum MenuBarIcon {
    private static var cache: [Bool: NSImage] = [:]

    static func image(running: Bool) -> NSImage {
        if let image = cache[running] { return image }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let front = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 15, height: 10), xRadius: 2.5, yRadius: 2.5)
            // The card behind, set apart from the front one by a thin gap so it reads as a second card.
            NSBezierPath(roundedRect: NSRect(x: 3.5, y: 8, width: 11, height: 8), xRadius: 2.2, yRadius: 2.2).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            front.lineWidth = 2.4
            front.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            front.fill()

            // Signs are cut out of the card, so they show the menu bar through it.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            if running {
                NSBezierPath(roundedRect: NSRect(x: 4.3, y: 4.1, width: 1.5, height: 4.8), xRadius: 0.5, yRadius: 0.5).fill()
                NSBezierPath(roundedRect: NSRect(x: 7.0, y: 4.1, width: 1.5, height: 4.8), xRadius: 0.5, yRadius: 0.5).fill()
            } else {
                let play = NSBezierPath()
                play.move(to: NSPoint(x: 4.4, y: 3.9))
                play.line(to: NSPoint(x: 4.4, y: 9.1))
                play.line(to: NSPoint(x: 8.9, y: 6.5))
                play.close()
                play.fill()
            }
            NSBezierPath(roundedRect: NSRect(x: 10.3, y: 7.4, width: 4, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
            NSBezierPath(roundedRect: NSRect(x: 10.3, y: 4.1, width: 2.6, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        image.isTemplate = true
        cache[running] = image
        return image
    }
}
