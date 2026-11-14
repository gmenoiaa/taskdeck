import Foundation
import AppKit

/// Opens links in the browser and profile a space names, so each company's tickets and pull
/// requests land where the user is signed in to them.
enum Browser {
    struct Kind: Identifiable, Hashable {
        let id: String
        let name: String
        let app: String
        /// The browser's settings folder inside Application Support; it holds the profile list.
        let support: String

        var isInstalled: Bool { FileManager.default.fileExists(atPath: app) }
    }

    struct Profile: Identifiable, Hashable {
        /// The profile's folder ("Default", "Profile 1"): what the browser wants on its command line.
        let directory: String
        /// The name the user gave it.
        let name: String
        var id: String { directory }
    }

    /// Browsers that take a profile on the command line. Both are Chromium, so they work the same way.
    static let kinds = [
        Kind(id: "chrome", name: "Google Chrome", app: "/Applications/Google Chrome.app", support: "Google/Chrome"),
        Kind(id: "edge", name: "Microsoft Edge", app: "/Applications/Microsoft Edge.app", support: "Microsoft Edge"),
    ]

    static func kind(_ id: String?) -> Kind? { kinds.first { $0.id == id } }

    /// The browser's profiles, by the names the user sees. Empty when the list cannot be read.
    static func profiles(of kind: Kind) -> [Profile] {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(kind.support).appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [] }
        return cache.map { directory, value in
            Profile(directory: directory, name: ((value as? [String: Any])?["name"] as? String) ?? directory)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Opens a link in the space's browser and profile; in the default browser when the space names
    /// none, the browser is gone, or the link is not a web page.
    static func open(_ url: URL, space: Project?) {
        guard let kind = kind(space?.browser), kind.isInstalled,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            NSWorkspace.shared.open(url)
            return
        }
        var arguments = ["-n", "-a", kind.app, "--args"]
        let profile = (space?.browserProfile ?? "").trimmingCharacters(in: .whitespaces)
        if !profile.isEmpty { arguments.append("--profile-directory=\(profile)") }
        arguments.append(url.absoluteString)
        // A running browser ignores arguments passed the usual way. Started as a new instance it
        // hands the link and the profile to the one already running, and then exits.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { NSWorkspace.shared.open(url) }
    }
}
