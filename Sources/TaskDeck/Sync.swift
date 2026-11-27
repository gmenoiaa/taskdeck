import Foundation

/// The version of what `data.json` holds. Raise it whenever a saved field is added, renamed or
/// changes meaning: a build only merges copies of its own version, and never saves over a file
/// written by a newer one (it would drop the fields it does not know).
enum SyncSchema {
    static let current = 1
}

/// This Mac, as told apart from the user's other Macs. Made once and kept in this Mac's user
/// defaults, never in the data file, which is shared.
enum Machine {
    static var id: String {
        let key = "machineId"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let made = UUID().uuidString
        UserDefaults.standard.set(made, forKey: key)
        return made
    }
}

/// When each synced record last changed, and when each deleted one went. Saved in `data.json`
/// beside the records, keyed like `SyncDocument.records` ("task:<id>", "space:<id>"…).
struct SyncMeta: Codable, Equatable {
    var modified: [String: Date] = [:]
    var deleted: [String: Date] = [:]
}

/// The part of the data that follows the user between Macs, one record at a time. A record's
/// value is its JSON as saved, with this Mac's own fields left out, so two copies can be compared
/// and the newer one chosen without knowing what kind of record it is.
struct SyncDocument: Codable, Equatable {
    var schema: Int
    var records: [String: Data] = [:]
    var meta = SyncMeta()
}

enum SyncMerge {
    /// How long a deletion is remembered. A copy that was apart for longer can bring a deleted
    /// record back.
    static let keepDeletions: TimeInterval = 30 * 86400

    enum Failure: LocalizedError, Equatable {
        case otherSchema(mine: Int, theirs: Int)

        var errorDescription: String? {
            switch self {
            case let .otherSchema(mine, theirs):
                return theirs > mine
                    ? "The other copy was saved by a newer TaskDeck (data version \(theirs), this one knows \(mine)). Update this Mac first."
                    : "The other copy was saved by an older TaskDeck (data version \(theirs), this one knows \(mine)). Update the other Mac first."
            }
        }
    }

    /// Record by record, the newest wins. A deletion wins over every change made before it, and a
    /// change made after a deletion brings the record back. On a tie this copy's version stays,
    /// so merging a copy with itself changes nothing. Deletions older than `keepDeletions` are
    /// forgotten.
    static func merge(_ mine: SyncDocument, _ theirs: SyncDocument, now: Date = Date()) throws -> SyncDocument {
        guard mine.schema == theirs.schema else {
            throw Failure.otherSchema(mine: mine.schema, theirs: theirs.schema)
        }
        var out = SyncDocument(schema: mine.schema)
        let keys = Set(mine.records.keys).union(theirs.records.keys)
            .union(mine.meta.deleted.keys).union(theirs.meta.deleted.keys)
        for key in keys {
            // The newer version of the record that still exists somewhere.
            var best: (value: Data, at: Date)?
            for side in [mine, theirs] {
                guard let value = side.records[key] else { continue }
                let at = side.meta.modified[key] ?? .distantPast
                if best == nil || at > best!.at { best = (value, at) }
            }
            let deletedAt = [mine.meta.deleted[key], theirs.meta.deleted[key]].compactMap { $0 }.max()
            if let deletedAt, deletedAt >= (best?.at ?? .distantPast) {
                if now.timeIntervalSince(deletedAt) < keepDeletions { out.meta.deleted[key] = deletedAt }
            } else if let best {
                out.records[key] = best.value
                if best.at != .distantPast { out.meta.modified[key] = best.at }
            }
        }
        return out
    }

    /// Brings the stamps up to date for what changed since the last save: a record whose JSON
    /// differs from `before` was changed now, one that is gone was deleted now. Deletions past
    /// `keepDeletions` are dropped.
    static func stamp(_ meta: SyncMeta, before: [String: Data], after: [String: Data], now: Date = Date()) -> SyncMeta {
        var meta = meta
        for (key, value) in after where before[key] != value {
            meta.modified[key] = now
            meta.deleted[key] = nil
        }
        for key in before.keys where after[key] == nil {
            meta.deleted[key] = now
            meta.modified[key] = nil
        }
        meta.deleted = meta.deleted.filter { now.timeIntervalSince($0.value) < keepDeletions }
        return meta
    }
}
