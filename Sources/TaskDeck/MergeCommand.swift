import Foundation

/// `TaskDeck merge <mine.json> <theirs.json> <out.json>`: merges two copies of `data.json` the
/// way two Macs will, and writes the result. For checking the merge by hand; it never touches the
/// app's own data file unless that is the path given as `out`.
enum MergeCommand {
    /// Nil when the arguments are not this command, so the app starts as usual; otherwise the
    /// exit status.
    static func runIfAsked(_ arguments: [String]) -> Int32? {
        guard arguments.count > 1, arguments[1] == "merge" else { return nil }
        guard arguments.count == 5 else {
            print("Usage: TaskDeck merge <mine.json> <theirs.json> <out.json>")
            return 2
        }
        do {
            let mine = try read(arguments[2])
            let theirs = try read(arguments[3])
            let merged = try SyncMerge.merge(mine.document(), theirs.document())
            let out = try mine.applying(merged)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(out).write(to: URL(fileURLWithPath: arguments[4]), options: .atomic)
            print("Merged: \(out.projects.count) spaces, \(out.tasks.count) tasks, \(out.goals?.count ?? 0) goals; \(merged.meta.deleted.count) deletions remembered.")
            return 0
        } catch {
            print("Not merged: \(error.localizedDescription)")
            return 1
        }
    }

    private static func read(_ path: String) throws -> AppStore.Snapshot {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try AppStore.Snapshot.recordDecoder.decode(AppStore.Snapshot.self, from: data)
    }
}
