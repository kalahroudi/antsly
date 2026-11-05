import XCTest
@testable import AntslyKit

final class WorkspaceTests: XCTestCase {
    func samplePage() -> Page {
        var p = Page(id: "p1", title: "Launch plan", blocks: [
            Block(id: "a", kind: .heading, text: "Goal"), Block(id: "b", kind: .text, text: "Ship it"),
            Block(id: "c", kind: .todo, text: "Demo", checked: true), Block(id: "d", kind: .bullet, text: "One"),
            Block(id: "e", kind: .callout, text: "Note"), Block(id: "f", kind: .code, text: "let x = 1\nlet y = 2")])
        for i in p.blocks.indices { p.blocks[i].stamp = 1 }   // a shared base, so only deliberate edits carry newer stamps
        return p
    }

    func testMarkdownRoundTrip() {
        let p = samplePage()
        let back = PageMarkdown.parse(PageMarkdown.render(p), fallbackID: "x", updated: 1)
        XCTAssertEqual(back.id, "p1"); XCTAssertEqual(back.title, "Launch plan")
        XCTAssertEqual(back.blocks.map(\.id), p.blocks.map(\.id))
        XCTAssertEqual(back.blocks.map(\.kind), p.blocks.map(\.kind))
        XCTAssertEqual(back.blocks.map(\.text), p.blocks.map(\.text))
        XCTAssertTrue(back.blocks[2].checked)
    }

    func testHandWrittenMarkdownGetsIDs() {
        let p = PageMarkdown.parse("# Hi\n\nHello\n\n- [ ] Task\n", fallbackID: "f", updated: 1)
        XCTAssertEqual(p.id, "f"); XCTAssertEqual(p.blocks.count, 2); XCTAssertEqual(p.blocks[1].kind, .todo)
    }

    func testMergeDifferentBlocksKeepsBoth() {
        var a = samplePage(), b = samplePage()
        a.blocks[1].text = "Ship it today"; a.blocks[1].stamp = 10
        b.blocks[3].text = "Two"; b.blocks[3].stamp = 11
        let m = PageMerge.merge(local: a, remote: b)
        XCTAssertEqual(m.blocks[1].text, "Ship it today"); XCTAssertEqual(m.blocks[3].text, "Two")
    }

    func testMergeSameBlockNewestWins() {
        var a = samplePage(), b = samplePage()
        a.blocks[1].text = "mine"; a.blocks[1].stamp = 10
        b.blocks[1].text = "theirs"; b.blocks[1].stamp = 20
        XCTAssertEqual(PageMerge.merge(local: a, remote: b).blocks[1].text, "theirs")
    }

    func testMergeKeepsLocalOnlyBlockAfterItsNeighbour() {
        var a = samplePage(); let b = samplePage()
        a.blocks.insert(Block(id: "new", text: "added"), at: 2)
        let ids = PageMerge.merge(local: a, remote: b).blocks.map(\.id)
        XCTAssertEqual(ids, ["a", "b", "new", "c", "d", "e", "f"])
    }

    func testDeletedBlockStaysDeleted() {
        let a = samplePage(); let b = samplePage()
        XCTAssertFalse(PageMerge.merge(local: a, remote: b, deleted: ["b"]).blocks.contains { $0.id == "b" })
    }

    func testStoreSaveLoadSearch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("antsly-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkspaceStore(root: dir)
        try s.save(samplePage())
        var db = Database.tasks(); db.rows = [.init(cells: ["name": "A", "status": "Open"])]
        try s.save(db)
        XCTAssertEqual(s.loadPages().count, 1); XCTAssertEqual(s.loadDatabases().first?.rows.count, 1)
        XCTAssertEqual(WorkspaceStore.search("SHIP", in: s.loadPages()).count, 1)
        XCTAssertTrue(WorkspaceStore.search("zzz", in: s.loadPages()).isEmpty)
    }

    func testCollabMessageCodecAndLines() {
        var buf = LineBuffer()
        let m1 = CollabMessage.hello(name: "Sara", device: "mac"), m2 = CollabMessage.page(samplePage())
        let wire = m1.encoded() + Data("\n".utf8) + m2.encoded() + Data("\n".utf8)
        let cut = wire.count / 2
        var out = buf.feed(wire.prefix(cut)); out += buf.feed(wire.suffix(from: cut))
        XCTAssertEqual(out.compactMap(CollabMessage.decode), [m1, m2])
    }

    func testTailscaleParse() {
        let json = #"{"BackendState":"Running","Self":{"DNSName":"mo-mac.tail1a2b.ts.net.","TailscaleIPs":["100.64.0.1","fd7a::1"]},"User":{"7":{"LoginName":"sara@x.com"}},"Peer":{"k":{"ID":"n1","HostName":"sara-mbp","TailscaleIPs":["100.64.0.2"],"Online":true,"UserID":7}}}"#
        let s = TailscaleStatus.parse(Data(json.utf8))
        XCTAssertEqual(s.state, .running); XCTAssertEqual(s.dnsName, "mo-mac.tail1a2b.ts.net"); XCTAssertEqual(s.ip, "100.64.0.1")
        XCTAssertEqual(s.peers.first?.user, "sara@x.com"); XCTAssertTrue(s.peers[0].online)
        XCTAssertEqual(TailscaleStatus.parse(Data(#"{"BackendState":"NeedsLogin"}"#.utf8)).state, .needsLogin)
    }

    func testInvite() {
        let i = Invite(host: "mo-mac.tail1a2b.ts.net", workspace: "Product wiki")
        XCTAssertEqual(Invite.parse(i.url), i)
        XCTAssertEqual(Invite.parse("antsly://join/mo-mac.ts.net:47935/Notes"), Invite(host: "mo-mac.ts.net", port: 47935, workspace: "Notes"))
        XCTAssertEqual(Invite.parse("antsly://join/mo-mac.ts.net/Notes")?.port, Invite.defaultPort)
        XCTAssertNil(Invite.parse("https://example.com")); XCTAssertNil(Invite.parse("antsly://join/"))
    }

    func testIssues() {
        let json = #"[{"number":42,"title":"Bug","state":"OPEN","assignees":[{"login":"mo"}],"labels":[{"name":"bug"}]},{"number":7,"title":"Old","state":"CLOSED","assignees":[],"labels":[]}]"#
        let issues = GitHubIssues.parse(Data(json.utf8))
        XCTAssertEqual(issues.map(\.number), [42, 7])
        let db = GitHubIssues.database(repo: "a/b", issues: issues)
        XCTAssertEqual(db.rows[0].cells["status"], "Open"); XCTAssertEqual(db.rows[1].cells["status"], "Closed"); XCTAssertEqual(db.lanes, ["Open", "Closed"])
        XCTAssertEqual(GitHubIssues.repoSlug(fromRemote: "git@github.com:kalahroudi/antsly.git"), "kalahroudi/antsly")
        XCTAssertEqual(GitHubIssues.repoSlug(fromRemote: "https://github.com/kalahroudi/antsly"), "kalahroudi/antsly")
        XCTAssertNil(GitHubIssues.repoSlug(fromRemote: "https://gitlab.com/a/b"))
    }

    func testGitHistoryAgainstRealRepo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("antsly-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = GitRepo(dir: dir)
        try await repo.initialize()
        let s = WorkspaceStore(root: dir); try s.save(samplePage())
        let saved = try await repo.saveVersion(message: "First draft")
        XCTAssertTrue(saved)
        let again = try await repo.saveVersion(message: "nothing")
        XCTAssertFalse(again)
        var p = samplePage(); p.blocks[1].text = "Changed"; try s.save(p)
        try await repo.saveVersion(message: "Reword")
        let log = await repo.log()
        XCTAssertEqual(log.map(\.subject), ["Reword", "First draft"])
        let diff = await repo.diff(of: log[0])
        XCTAssertTrue(diff.contains { $0.kind == .added && $0.text.contains("Changed") })
        XCTAssertTrue(diff.contains { $0.kind == .removed && $0.text.contains("Ship it") })
    }
}

final class UndoTests: XCTestCase {
    func testTypingCoalescesButStructureDoesNot() {
        var h = UndoHistory<[String]>()
        let t0 = Date(timeIntervalSince1970: 1000)
        h.record(key: "page:a:1", state: ["v0"], now: t0)
        h.record(key: "page:a:1", state: ["v1"], now: t0.addingTimeInterval(0.3))      // same phrase: no new step
        h.record(key: "page:a:2", state: ["v2"], now: t0.addingTimeInterval(0.4))      // a block was added: new step
        XCTAssertEqual(h.undo(current: ["now"]), ["v2"])
        XCTAssertEqual(h.undo(current: ["v2"]), ["v0"])
        XCTAssertNil(h.undo(current: ["v0"]))
    }
    func testPauseStartsNewStepAndRedoWorksUntilNewEdit() {
        var h = UndoHistory<Int>()
        let t0 = Date(timeIntervalSince1970: 1000)
        h.record(key: "k", state: 1, now: t0)
        h.record(key: "k", state: 2, now: t0.addingTimeInterval(2))                    // paused: new step
        XCTAssertEqual(h.undo(current: 3), 2); XCTAssertTrue(h.canRedo)
        XCTAssertEqual(h.redo(current: 2), 3)
        XCTAssertEqual(h.undo(current: 3), 2)
        h.record(key: "other", state: 9, now: t0.addingTimeInterval(5))                // a new edit clears redo
        XCTAssertFalse(h.canRedo)
    }
    func testLimit() {
        var h = UndoHistory<Int>(limit: 3)
        for i in 0..<10 { h.record(key: "\(i)", state: i, now: Date(timeIntervalSince1970: Double(i) * 10)) }
        var n = 0; var cur = 99
        while let s = h.undo(current: cur) { cur = s; n += 1 }
        XCTAssertEqual(n, 3)
    }
}
