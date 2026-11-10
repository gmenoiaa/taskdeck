import SwiftUI
import AppKit

// Liquid Glass (macOS 26+) helpers, with a material fallback for older systems.
// Glass is used only for the floating control layer; cards and columns stay as content.

extension View {
    /// A row of floating actions that content scrolls beneath. On macOS 26+ each button is its
    /// own glass capsule (no bar behind them: glass on glass looks boxy).
    @ViewBuilder
    func actionBar() -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { self }
                .buttonStyle(.glass)
                // Neutral (gray) glass: the app's red tint would paint every button solid red.
                .tint(nil)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 6)
        } else {
            self.padding(14)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
        }
    }

    /// The main action of a floating row: tinted glass on macOS 26+.
    @ViewBuilder
    func primaryGlass() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(Theme.accent)
        } else {
            self.buttonStyle(.borderedProminent).tint(Theme.accent)
        }
    }

    /// Soft fade where scrolling content meets a floating bar.
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

enum Radius {
    /// Larger, continuous corners that sit well inside the rounder macOS 26 windows.
    static let card: CGFloat = 12
    static let column: CGFloat = 18
}

enum Theme {
    /// The app's signature red (from the icon): accent for links, buttons, highlights and running timers.
    /// Lighter in dark mode to stay readable. Errors keep the system red.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.00, green: 0.45, blue: 0.42, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.12, blue: 0.18, alpha: 1)
    })
}

/// A ticket number that opens the ticket in the browser, drawn in the app's red.
/// (SwiftUI's Link ignores tint on macOS and always uses the system link blue.)
struct TicketLink: View {
    let text: String
    let url: URL

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Text(text).foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
