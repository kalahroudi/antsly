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

    // MARK: Database columns, group actions, agent prompts

    func testOldColumnsInferTheirKind() throws {
        let json = #"{"id":"d","title":"T","columns":[{"id":"status","name":"Status"},{"id":"owner","name":"Owner"},{"id":"due","name":"Due"},{"id":"x","name":"X"}],"rows":[]}"#
        let db = try JSONDecoder().decode(Database.self, from: Data(json.utf8))
        XCTAssertEqual(db.columns.map(\.kind), [.status, .person, .date, .text])
        XCTAssertEqual(db.columns[0].options, ColumnKind.status.defaultOptions)
    }

    func testColumnKindRoundTrips() throws {
        var db = Database.tasks(); db.columns[1] = .init(id: "status", name: "Stage", kind: .select, options: ["A", "B"])
        let back = try JSONDecoder().decode(Database.self, from: JSONEncoder().encode(db))
        XCTAssertEqual(back, db)
    }

    func testGroupDeleteAndUpdate() {
        var db = Database.tasks()
        db.rows = (1...4).map { Database.Row(id: "r\($0)", cells: ["name": "T\($0)", "status": "Not started"]) }
        db.setCells(["r1", "r3"], column: "status", to: "Done")
        XCTAssertEqual(db.rows.map { $0.cells["status"] ?? "" }, ["Done", "Not started", "Done", "Not started"])
        db.removeRows(["r2", "r3"])
        XCTAssertEqual(db.rows.map(\.id), ["r1", "r4"])
    }

    func testChoicesIncludeValuesAlreadyUsed() {
        var db = Database.tasks(); db.rows = [.init(cells: ["owner": "Sam"])]
        db.columns[2].options = ["Ana"]
        XCTAssertEqual(db.choices(for: db.columns[2]), ["Ana", "Sam"])
    }

    func testStatusToneAndDates() {
        XCTAssertEqual(StatusTone.of("Done"), .done); XCTAssertEqual(StatusTone.of("Blocked"), .blocked)
        XCTAssertEqual(StatusTone.of("In progress"), .active); XCTAssertEqual(StatusTone.of("Later"), .neutral)
        XCTAssertEqual(CellDate.format(CellDate.parse("2026-11-05")!), "2026-11-05"); XCTAssertNil(CellDate.parse("soon"))
    }

    func testAgentPromptNamesOnlyThePickedRows() {
        var db = Database.tasks(); db.rows = [.init(id: "a", cells: ["name": "Fix login"]), .init(id: "b", cells: ["name": "Other"])]
        let p = AgentTask.fix.prompt(for: db, rows: [db.rows[0]], file: "databases/x.json")
        XCTAssertTrue(p.contains("Fix login")); XCTAssertFalse(p.contains("Other")); XCTAssertTrue(p.contains("databases/x.json"))
        XCTAssertTrue(AgentTask.stylePrompt(for: db, file: "f").contains("kind"))
    }

    // MARK: Drag and drop: organising text and importing assets

    func testOrganizerSortsPastedNotes() {
        let text = """
        Plan for Friday:
        - [ ] Book the room
        - [x] Send the invite
        * Bring laptops
        1. Agenda first
        > Remember the demo

        Thanks for reading this note about the plan that was wrapped by the sender and carries on
        onto a second line here.
        """
        let b = ContentOrganizer.blocks(from: text)
        XCTAssertEqual(b.map(\.kind), [.heading, .todo, .todo, .bullet, .bullet, .callout, .text])
        XCTAssertEqual(b[0].text, "Plan for Friday"); XCTAssertFalse(b[1].checked); XCTAssertTrue(b[2].checked)
        XCTAssertTrue(b[6].text.hasSuffix("onto a second line here."))
        XCTAssertEqual(ContentOrganizer.blocks(from: "From: Sam\nSubject: Hello").map(\.text), ["From: Sam", "Subject: Hello"])
        XCTAssertTrue(ContentOrganizer.blocks(from: "  \n ").isEmpty)
    }

    func testAIReplyParsing() {
        let reply = "Here you go:\n```json\n[{\"kind\":\"todo\",\"text\":\"Call Sam\",\"checked\":true},{\"kind\":\"image\",\"text\":\"odd\"},{\"kind\":\"heading\",\"text\":\"\"}]\n```"
        let b = AIOrganizer.parse(reply)
        XCTAssertEqual(b?.map(\.kind), [.todo, .text]); XCTAssertEqual(b?.first?.checked, true)
        XCTAssertNil(AIOrganizer.parse("no json here"))
        XCTAssertNil(AIOrganizer.parse("[]"))
    }

    func testImportAssetsKeepsNamesUniqueAndSafe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("antsly-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkspaceStore(root: dir)
        let a = try store.importAsset(data: Data("one".utf8), name: "My report (final).pdf")
        let b = try store.importAsset(data: Data("two".utf8), name: "My report (final).pdf")
        XCTAssertEqual(a, "assets/My-report--final-.pdf"); XCTAssertEqual(b, "assets/My-report--final--2.pdf")
        XCTAssertEqual(try String(contentsOf: store.assetURL(a), encoding: .utf8), "one")
        XCTAssertEqual(WorkspaceStore.assetBlock(for: "assets/shot.PNG").kind, .image)
        XCTAssertEqual(WorkspaceStore.assetBlock(for: a).kind, .file)
    }

    func testAssetBlocksSurviveMarkdown() {
        let p = Page(id: "p", title: "T", blocks: [Block(id: "i", kind: .image, text: "assets/shot.png"), Block(id: "f", kind: .file, text: "assets/plan.pdf"), Block(id: "t", kind: .text, text: "after")])
        let md = PageMarkdown.render(p)
        XCTAssertTrue(md.contains("![shot.png](assets/shot.png)")); XCTAssertTrue(md.contains("[plan.pdf](assets/plan.pdf)"))
        let back = PageMarkdown.parse(md, fallbackID: "x", updated: 1)
        XCTAssertEqual(back.blocks.map(\.kind), [.image, .file, .text]); XCTAssertEqual(back.blocks.map(\.text), ["assets/shot.png", "assets/plan.pdf", "after"])
        XCTAssertEqual(back.blocks.map(\.id), ["i", "f", "t"])
    }

    // MARK: Rich rendering

    func testInlineMarkdownRenders() {
        let a = InlineMarkdown.attributed("Ship **now**, see [docs](https://example.com/a) or https://example.org/x.")
        XCTAssertEqual(String(a.characters), "Ship now, see docs or https://example.org/x.")
        let links = a.runs.compactMap(\.link).map(\.absoluteString)
        XCTAssertEqual(links, ["https://example.com/a", "https://example.org/x"])   // the full stop is not part of the address
        XCTAssertTrue(a.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    func testInlineMarkdownLeavesOddTextAlone() {
        XCTAssertEqual(String(InlineMarkdown.attributed("2 * 3 = 6 and snake_case_name").characters), "2 * 3 = 6 and snake_case_name")
        XCTAssertFalse(InlineMarkdown.hasMarkup("Just a plain sentence."))
        XCTAssertTrue(InlineMarkdown.hasMarkup("Visit https://example.com"))
        XCTAssertEqual(InlineMarkdown.attributed("[a](https://x.io)").runs.compactMap(\.link).count, 1)   // not linkified twice
    }
}
