import XCTest
@testable import AntslyKit

final class KitTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertTrue(Version.isNewer("0.2.0", than: "0.1.9"))
        XCTAssertTrue(Version.isNewer("v1.0.0", than: "1.0.0-beta.2"))
        XCTAssertFalse(Version.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(Version.isNewer("garbage", than: "1.0.0"))
    }

    func testChecksumLookup() {
        let sums = "abc123  Antsly-0.1.0.dmg\ndef456 *other.dmg\n"
        XCTAssertEqual(UpdateChecker.checksum(in: sums, for: "Antsly-0.1.0.dmg"), "abc123")
        XCTAssertEqual(UpdateChecker.checksum(in: sums, for: "other.dmg"), "def456")
        XCTAssertNil(UpdateChecker.checksum(in: sums, for: "missing.dmg"))
    }

    func testCompareDecision() throws {
        let ahead = Data(#"{"status":"ahead","ahead_by":1,"commits":[{"commit":{"message":"Fix a thing\n\nbody"}}]}"#.utf8)
        guard case .available(let info) = try UpdateChecker.decide(compareJSON: ahead, head: "deadbeef") else { return XCTFail("expected available") }
        XCTAssertEqual(info.summaries, ["Fix a thing"])
        XCTAssertEqual(try UpdateChecker.decide(compareJSON: Data(#"{"status":"identical"}"#.utf8), head: "x"), .upToDate)
    }

    func testSwapScriptRollsBack() {
        XCTAssertTrue(UpdateSwap.script.contains("restored"))
    }

    func testAgentConfigRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"other":1,"mcpServers":{"keep":{"command":"x"}}}"#.utf8).write(to: url)
        try AgentIntegrations.jsonInstall(at: url, command: "/Applications/Antsly.app/Contents/MacOS/antsly-mcp")
        XCTAssertEqual(AgentIntegrations.jsonCommand(at: url), "/Applications/Antsly.app/Contents/MacOS/antsly-mcp")
        try AgentIntegrations.jsonRemove(at: url)
        XCTAssertNil(AgentIntegrations.jsonCommand(at: url))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertNotNil((root?["mcpServers"] as? [String: Any])?["keep"], "other servers must survive")
        XCTAssertEqual(root?["other"] as? Int, 1)
    }

    func testSetupStateWithNothingMissingIsReady() {
        XCTAssertTrue(SetupState(items: []).ready)
    }

    // MARK: sessions (crash safety)
    private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sess-\(UUID().uuidString)") }

    func testSessionsSurviveCleanRestart() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionStore(directory: dir); _ = a.load()
        var idx = SessionIndex(); let m = SessionMeta(title: "one"); idx.sessions = [m]; idx.selected = m.id
        try a.saveIndex(idx); try a.writePayload(m.id, Data("hello".utf8)); a.markCleanShutdown()
        let b = SessionStore(directory: dir).load()
        XCTAssertFalse(b.recoveredFromCrash)
        XCTAssertEqual(b.index.sessions.map(\.title), ["one"])
        XCTAssertEqual(SessionStore(directory: dir).readPayload(m.id), Data("hello".utf8))
    }

    func testCrashRestoresAndMarksRunningAsInterrupted() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionStore(directory: dir); _ = a.load()
        var idx = SessionIndex(); idx.sessions = [SessionMeta(title: "busy", status: .busy), SessionMeta(title: "idle")]
        try a.saveIndex(idx)                       // no markCleanShutdown: simulates a crash / kill -9
        let b = SessionStore(directory: dir).load()
        XCTAssertTrue(b.recoveredFromCrash)
        XCTAssertEqual(b.index.sessions.map(\.status), [.interrupted, .idle])
    }

    func testCorruptIndexFallsBackToBackupAndIsQuarantined() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionStore(directory: dir); _ = a.load()
        var idx = SessionIndex(); idx.sessions = [SessionMeta(title: "keep")]
        try a.saveIndex(idx); try a.saveIndex(idx)  // second save leaves index.json.bak
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("index.json"))
        let b = SessionStore(directory: dir).load()
        XCTAssertEqual(b.index.sessions.map(\.title), ["keep"])
        XCTAssertEqual(b.quarantined, ["index.json.corrupt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.json.corrupt").path))
    }
}
