import Foundation

/// One notification, as every channel gets it: plain text, and what it is about, so each channel
/// can be given only some kinds.
struct Notice {
    enum Kind: String, CaseIterable, Identifiable {
        case sessions, pullRequests, assigned, reminders, standup, time
        /// "Send a test": goes to every channel that is on, whatever kinds it takes.
        case test

        var id: String { rawValue }

        /// The kinds a channel can choose between.
        static let choosable: [Kind] = [.sessions, .pullRequests, .assigned, .reminders, .standup, .time]

        var label: String {
            switch self {
            case .sessions: return "Agent sessions"
            case .pullRequests: return "Pull requests"
            case .assigned: return "Tickets assigned to me"
            case .reminders: return "Task reminders"
            case .standup: return "Daily standup"
            case .time: return "Time and timers"
            case .test: return "Test"
            }
        }
    }

    var kind: Kind
    var title: String
    var subtitle: String?
    var body: String
    /// Where a click should go, when the notification is about something with a page.
    var link: URL?

    var text: String { [subtitle, body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n") }
}

/// Somewhere a notification goes besides the banner on this Mac: a phone, a chat. Adding a service
/// is one type that implements this and an entry in `Notifier.channels`.
protocol NotificationChannel: Sendable {
    /// Saved in `data.json` (`NotificationSettings.channels`); never change it.
    var id: String { get }
    var label: String { get }
    /// Whether the keys it needs are set.
    var isConfigured: Bool { get }
    /// What leaves this Mac when it is on, in plain words for the settings.
    var privacyNote: String { get }
    func deliver(_ notice: Notice) async throws
}

/// Whether a channel is on, and which kinds go to it. Kinds are saved as their raw names, so a
/// file from a newer version with a kind this one does not know still loads.
struct ChannelSettings: Codable, Equatable {
    var enabled = false
    var kinds: [String] = [Notice.Kind.sessions, .pullRequests, .assigned, .reminders].map(\.rawValue)
    /// Send only while the user is away from this Mac; the banner is enough while they are at it.
    /// Optional, like `awayMinutes`, so files saved before the option existed still load.
    var onlyWhenAway: Bool?
    /// How long without a key press or pointer movement counts as away.
    var awayMinutes: Int?

    var awayOnly: Bool { onlyWhenAway ?? false }
    var idleMinutes: Int { awayMinutes ?? 5 }

    /// Whether a notice of this kind goes to the channel now. A test always goes.
    func sends(_ kind: Notice.Kind) -> Bool {
        guard enabled else { return false }
        if kind == .test { return true }
        guard kinds.contains(kind.rawValue) else { return false }
        return !awayOnly || UserActivity.isAway(idleMinutes: idleMinutes)
    }
}

/// Pushover (pushover.net): one HTTPS request per notification, shown by its iPhone, Android and
/// desktop apps. Needs the user key of the account and the token of an application made there.
struct PushoverChannel: NotificationChannel {
    static let id = "pushover"
    var id: String { Self.id }
    let label = "Pushover"
    let privacyNote = "When this is on, the text of each notification sent to it (task and ticket titles, what an agent asked or answered, pull request comments) goes to Pushover's servers and from there to your devices."

    /// Keychain accounts, service `local.taskdeck`.
    static let userAccount = "pushover-user"
    static let tokenAccount = "pushover-token"

    var isConfigured: Bool {
        !(Keychain.get(account: Self.userAccount) ?? "").isEmpty && !(Keychain.get(account: Self.tokenAccount) ?? "").isEmpty
    }

    func deliver(_ notice: Notice) async throws {
        guard let user = Keychain.get(account: Self.userAccount), !user.isEmpty,
              let token = Keychain.get(account: Self.tokenAccount), !token.isEmpty else {
            throw ToolFailure.failed("The Pushover user key or application token is not set.")
        }
        // Pushover's limits: 250 characters of title, 1024 of message, 512 of link.
        var fields = [
            "token": token,
            "user": user,
            "title": String(notice.title.prefix(250)),
            "message": String((notice.text.isEmpty ? notice.title : notice.text).prefix(1024)),
        ]
        if let link = notice.link?.absoluteString, link.count <= 512 { fields["url"] = link }

        var request = URLRequest(url: URL(string: "https://api.pushover.net/1/messages.json")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.form(fields).utf8)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, reply?["status"] as? Int == 1 else {
            // Pushover explains a refusal in "errors"; the key and token are never part of it.
            let errors = (reply?["errors"] as? [String])?.joined(separator: " ")
            throw ToolFailure.failed(errors ?? "Pushover answered with status \(status).")
        }
    }

    private static func form(_ fields: [String: String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}
