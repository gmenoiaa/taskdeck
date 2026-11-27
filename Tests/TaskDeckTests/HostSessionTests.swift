import XCTest
@testable import TaskDeck

final class HostSessionTests: XCTestCase {
    private func published(_ kind: SessionStatus.Kind) -> PublishedSession {
        let session = AgentSession(worktreeId: "claude-code:abc123", path: "/Users/someone/repo", name: "s", repoName: "repo",
                                   agent: "claude", claudeHome: "~/.claude-x", runner: ClaudeCodeRunner.id)
        var status = SessionStatus(kind: kind, lastMessage: "Done", prNumber: 7)
        status.prURL = URL(string: "https://github.com/o/r/pull/7")
        return PublishedSession(session, status: status)
    }

    func testOtherMacsRecordsAreTakenAndThisMacsOwnIsNot() throws {
        let taskId = UUID().uuidString
        var mine = AppStore.Snapshot(projects: [], tasks: [])
        mine.hosts = [Machine.id: HostState(name: "Here")]
        // The other Mac sends its own record and a stale copy of this Mac's.
        var theirs = AppStore.Snapshot(projects: [], tasks: [])
        theirs.hosts = ["other-mac": HostState(name: "Deskserver", sessions: [taskId: [published(.yourTurn)]]),
                        Machine.id: HostState(name: "Stale copy of this Mac", sessions: [taskId: [published(.working)]])]
        var theirDoc = theirs.document()
        for key in theirDoc.records.keys { theirDoc.meta.modified[key] = Date() }
        let merged = try mine.applying(SyncMerge.merge(mine.document(), theirDoc))
        XCTAssertEqual(merged.hosts?["other-mac"]?.name, "Deskserver")
        XCTAssertEqual(merged.hosts?[Machine.id]?.name, "Here")
        XCTAssertNil(merged.hosts?[Machine.id]?.sessions[taskId])
    }

    func testPublishedSessionsCarryNoPathsAndComeBackReadOnly() throws {
        let item = published(.yourTurn)
        let json = String(decoding: try AppStore.Snapshot.recordEncoder.encode(item), as: UTF8.self)
        XCTAssertFalse(json.contains("/Users/someone"))
        XCTAssertFalse(json.contains(".claude-x"))
        let session = item.session(host: "other-mac")
        XCTAssertTrue(session.isRemote)
        XCTAssertNil(Runners.of(session))
        XCTAssertEqual(item.status.kind, .yourTurn)
        XCTAssertEqual(item.status.prNumber, 7)
    }

    func testRunOnFollowsTheTask() {
        var task = TaskItem(title: "Queued")
        task.runOn = "deskserver-id"
        XCTAssertEqual(task.synced.runOn, "deskserver-id")
    }
}
