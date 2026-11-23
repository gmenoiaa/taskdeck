import Foundation

/// The last copy of each ticket read from its tracker, kept on disk so the details open at once
/// and are brought up to date in the background. One small file per task, beside `data.json`;
/// losing them only costs a spinner the next time.
@MainActor
enum TicketCache {
    struct Entry: Codable {
        var detail: TicketDetail
        var options: TicketOptions?
        var savedAt = Date()
    }

    private static var folder: URL {
        AppStore.dataURL.deletingLastPathComponent().appendingPathComponent("tickets", isDirectory: true)
    }

    private static func file(_ taskId: UUID) -> URL {
        folder.appendingPathComponent("\(taskId.uuidString).json")
    }

    static func load(_ taskId: UUID) -> Entry? {
        guard let data = try? Data(contentsOf: file(taskId)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    static func save(_ entry: Entry, for taskId: UUID) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: file(taskId), options: .atomic) }
    }

    static func remove(_ taskId: UUID) {
        try? FileManager.default.removeItem(at: file(taskId))
    }
}

// By hand: `meta` is a list of pairs, which Swift cannot encode on its own.
extension TicketDetail: Codable {
    private enum CodingKeys: String, CodingKey {
        case kindLabel, subject, status, meta, links, description, markdown, comments, estimatedHours, totalSpentHours
        case tracksEstimate, devEstimate, dueDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kindLabel: try c.decodeIfPresent(String.self, forKey: .kindLabel),
                  subject: try c.decode(String.self, forKey: .subject),
                  status: try c.decodeIfPresent(String.self, forKey: .status))
        meta = (try c.decodeIfPresent([[String]].self, forKey: .meta) ?? []).compactMap {
            $0.count == 2 ? ($0[0], $0[1]) : nil
        }
        links = try c.decodeIfPresent([String: URL].self, forKey: .links) ?? [:]
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        markdown = try c.decodeIfPresent(Bool.self, forKey: .markdown) ?? false
        comments = try c.decodeIfPresent([Comment].self, forKey: .comments) ?? []
        estimatedHours = try c.decodeIfPresent(Double.self, forKey: .estimatedHours)
        totalSpentHours = try c.decodeIfPresent(Double.self, forKey: .totalSpentHours)
        tracksEstimate = try c.decodeIfPresent(Bool.self, forKey: .tracksEstimate) ?? false
        devEstimate = try c.decodeIfPresent(DevEstimate.self, forKey: .devEstimate)
        dueDay = try c.decodeIfPresent(String.self, forKey: .dueDay)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(kindLabel, forKey: .kindLabel)
        try c.encode(subject, forKey: .subject)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encode(meta.map { [$0.0, $0.1] }, forKey: .meta)
        try c.encode(links, forKey: .links)
        try c.encode(description, forKey: .description)
        try c.encode(markdown, forKey: .markdown)
        try c.encode(comments, forKey: .comments)
        try c.encodeIfPresent(estimatedHours, forKey: .estimatedHours)
        try c.encodeIfPresent(totalSpentHours, forKey: .totalSpentHours)
        try c.encode(tracksEstimate, forKey: .tracksEstimate)
        try c.encodeIfPresent(devEstimate, forKey: .devEstimate)
        try c.encodeIfPresent(dueDay, forKey: .dueDay)
    }
}
