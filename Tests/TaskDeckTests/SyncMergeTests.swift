import XCTest
@testable import TaskDeck

final class SyncMergeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func doc(_ records: [String: (String, Double?)], deleted: [String: Double] = [:], schema: Int = 1) -> SyncDocument {
        var out = SyncDocument(schema: schema)
        for (key, (value, minute)) in records {
            out.records[key] = data(value)
            if let minute { out.meta.modified[key] = at(minute) }
        }
        for (key, minute) in deleted { out.meta.deleted[key] = at(minute) }
        return out
    }

    // MARK: Merge rules

    func testNewerEditWinsEitherWay() throws {
        let mine = doc(["a": ("mine", 5), "b": ("mine", 9)])
        let theirs = doc(["a": ("theirs", 7), "b": ("theirs", 3)])
        let merged = try SyncMerge.merge(mine, theirs, now: at(10))
        XCTAssertEqual(merged.records["a"], data("theirs"))
        XCTAssertEqual(merged.meta.modified["a"], at(7))
        XCTAssertEqual(merged.records["b"], data("mine"))
    }

    func testRecordsOnOneSideOnlyAreKept() throws {
        let merged = try SyncMerge.merge(doc(["a": ("a", 1)]), doc(["b": ("b", 2)]), now: at(10))
        XCTAssertEqual(Set(merged.records.keys), ["a", "b"])
    }

    func testDeletionWinsOverOlderEdit() throws {
        let mine = doc(["a": ("edited", 4)])
        let theirs = doc([:], deleted: ["a": 6])
        let merged = try SyncMerge.merge(mine, theirs, now: at(10))
        XCTAssertNil(merged.records["a"])
        XCTAssertEqual(merged.meta.deleted["a"], at(6))
        // The same from the other side.
        let back = try SyncMerge.merge(theirs, mine, now: at(10))
        XCTAssertNil(back.records["a"])
    }

    func testEditAfterDeletionBringsTheRecordBack() throws {
        let mine = doc([:], deleted: ["a": 4])
        let theirs = doc(["a": ("edited later", 6)])
        let merged = try SyncMerge.merge(mine, theirs, now: at(10))
        XCTAssertEqual(merged.records["a"], data("edited later"))
        XCTAssertNil(merged.meta.deleted["a"])
    }

    func testTieKeepsMineAndMergingWithItselfChangesNothing() throws {
        let mine = doc(["a": ("mine", 5)], deleted: ["gone": 2])
        let theirs = doc(["a": ("theirs", 5)])
        XCTAssertEqual(try SyncMerge.merge(mine, theirs, now: at(10)).records["a"], data("mine"))
        XCTAssertEqual(try SyncMerge.merge(mine, mine, now: at(10)), mine)
    }

    func testUnstampedRecordLosesToAnyStampedOne() throws {
        // Records saved before stamps existed have no time; any real edit is newer.
        let merged = try SyncMerge.merge(doc(["a": ("old file", nil)]), doc(["a": ("edited", 1)]), now: at(10))
        XCTAssertEqual(merged.records["a"], data("edited"))
    }

    func testOldDeletionsAreForgotten() throws {
        let mine = doc([:], deleted: ["a": 0])
        let later = at(0).addingTimeInterval(SyncMerge.keepDeletions + 60)
        XCTAssertNil(try SyncMerge.merge(mine, doc([:]), now: later).meta.deleted["a"])
    }

    func testOtherSchemaIsRefused() {
        XCTAssertThrowsError(try SyncMerge.merge(doc([:], schema: 1), doc([:], schema: 2))) { error in
            XCTAssertEqual(error as? SyncMerge.Failure, .otherSchema(mine: 1, theirs: 2))
        }
    }

    // MARK: Stamping on save

    func testStampMarksChangesAndDeletions() {
        let before = ["same": data("1"), "changed": data("1"), "removed": data("1")]
        let after = ["same": data("1"), "changed": data("2"), "added": data("1")]
        var meta = SyncMeta()
        meta.modified["same"] = at(1)
        let stamped = SyncMerge.stamp(meta, before: before, after: after, now: at(5))
        XCTAssertEqual(stamped.modified["same"], at(1))
        XCTAssertEqual(stamped.modified["changed"], at(5))
        XCTAssertEqual(stamped.modified["added"], at(5))
        XCTAssertEqual(stamped.deleted["removed"], at(5))
        XCTAssertNil(stamped.modified["removed"])
    }

    // MARK: Records of a snapshot

    func testMergedSnapshotKeepsThisMacsOwnFields() throws {
        let spaceId = UUID(), taskId = UUID()
        var space = Project(id: spaceId, name: "Work")
        space.claudeHome = "~/.claude-work"
        space.orcaRepoIds = ["repo-on-this-mac"]
        var task = TaskItem(id: taskId, projectId: spaceId, title: "Old title")
        task.sessions = [AgentSession(name: "session-here", repoName: "repo", agent: "claude")]
        var mine = AppStore.Snapshot(projects: [space], tasks: [task])
        mine.agentQueueLimit = 3
        mine.claudeModel = "mine-model"

        // The other Mac renamed the task, added one, has no sessions, other settings and other folders.
        var theirSpace = space.synced
        theirSpace.claudeHome = "~/.claude-other"
        var renamed = task.synced
        renamed.title = "New title"
        let added = TaskItem(projectId: spaceId, title: "Added elsewhere")
        var theirs = AppStore.Snapshot(projects: [theirSpace], tasks: [renamed, added])
        theirs.agentQueueLimit = 6
        theirs.claudeModel = "their-model"

        var mineDoc = mine.document()
        var theirDoc = theirs.document()
        for key in theirDoc.records.keys { theirDoc.meta.modified[key] = at(5) }
        for key in mineDoc.records.keys { mineDoc.meta.modified[key] = at(1) }

        let merged = try mine.applying(SyncMerge.merge(mineDoc, theirDoc, now: at(10)))
        XCTAssertEqual(merged.tasks.map(\.title), ["New title", "Added elsewhere"])
        XCTAssertEqual(merged.tasks[0].sessions?.first?.name, "session-here")
        XCTAssertNil(merged.tasks[1].sessions)
        XCTAssertEqual(merged.projects[0].claudeHome, "~/.claude-work")
        XCTAssertEqual(merged.projects[0].orcaRepoIds, ["repo-on-this-mac"])
        XCTAssertEqual(merged.claudeModel, "their-model")
        XCTAssertEqual(merged.agentQueueLimit, 3)
    }

    func testMachineFieldsDoNotMakeARecordDiffer() {
        var space = Project(name: "Work")
        let before = AppStore.Snapshot(projects: [space], tasks: []).syncRecords()
        space.claudeHome = "~/.claude-other"
        space.browser = "chrome"
        let after = AppStore.Snapshot(projects: [space], tasks: []).syncRecords()
        XCTAssertEqual(before, after)
    }

    func testTimersStartedOnAnotherMacAreNotLocal() {
        XCTAssertTrue(TimeEntry(start: t0).isLocal)
        XCTAssertTrue(TimeEntry(start: t0, machine: Machine.id).isLocal)
        XCTAssertFalse(TimeEntry(start: t0, machine: "another-mac").isLocal)
    }
}

final class DataFileGuardTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    @MainActor func testFileFromANewerVersionLoadsButIsNotSavedOver() {
        let json = #"{"projects": [], "tasks": [], "schema": \#(SyncSchema.current + 1), "aFieldThisBuildDoesNotKnow": 1}"#
        let (snapshot, blocked) = AppStore.read(Data(json.utf8), decoder: decoder)
        XCTAssertNotNil(snapshot)
        XCTAssertNotNil(blocked)
    }

    @MainActor func testUnreadableFileIsNotSavedOver() {
        let (snapshot, blocked) = AppStore.read(Data("not json".utf8), decoder: decoder)
        XCTAssertNil(snapshot)
        XCTAssertNotNil(blocked)
    }

    @MainActor func testFileFromBeforeVersionsLoadsAndSaves() {
        let (snapshot, blocked) = AppStore.read(Data(#"{"projects": [], "tasks": []}"#.utf8), decoder: decoder)
        XCTAssertNotNil(snapshot)
        XCTAssertNil(blocked)
    }

    @MainActor func testNoFileIsAFirstLaunch() {
        let (snapshot, blocked) = AppStore.read(nil, decoder: decoder)
        XCTAssertNil(snapshot)
        XCTAssertNil(blocked)
    }
}
