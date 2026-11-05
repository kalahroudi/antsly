// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AntslyKit

/// Everything the user is working on: pages, databases and plans, plus saving, search, history and sharing.
/// Edits are written 0.6 s after the last keystroke and flushed when the window closes or the app quits, so a crash loses almost nothing.
@MainActor @Observable
final class WorkspaceModel {
    static let shared = WorkspaceModel()

    enum Item: Hashable { case page(String), database(String), plan(String) }

    private(set) var store: WorkspaceStore
    var pages: [Page] = []
    var databases: [Database] = []
    var plans: [Plan] = []
    var selected: Item?
    var query = ""
    var loaded = false

    // Undo and redo. Whole-workspace snapshots, merged while you keep typing in the same place.
    struct Snap { var pages: [Page]; var databases: [Database]; var plans: [Plan] }
    @ObservationIgnored private var history = UndoHistory<Snap>()
    private(set) var canUndo = false
    private(set) var canRedo = false

    // Version history and git sharing
    var commits: [Commit] = []
    var diff: [DiffLine] = []
    var selectedCommit: Commit?
    var gitBusy = false
    var gitNote = ""
    var conflicts: [String] = []
    var remote: String?

    @ObservationIgnored private var dirtyPages = Set<String>()
    @ObservationIgnored private var dirtyDBs = Set<String>()
    @ObservationIgnored private var dirtyPlans = Set<String>()
    @ObservationIgnored private var deletedBlocks: [String: Set<String>] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastDisk: Date = .distantPast
    @ObservationIgnored private var lastCommitAt: Date = .distantPast

    private init() { store = WorkspaceStore(root: URL(fileURLWithPath: Prefs.shared.workspacePath)) }

    var repo: GitRepo { GitRepo(dir: store.root) }
    var searchResults: [Page] { WorkspaceStore.search(query, in: pages) }

    // MARK: Loading

    /// Screenshots only: a throwaway workspace with made-up content, never the user's real data.
    func loadDemo(pages p: [Page], databases d: [Database], plans pl: [Plan]) {
        store = WorkspaceStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("antsly-demo-\(UUID().uuidString)"))
        pages = p; databases = d; plans = pl; selected = .page(p[0].id); loaded = true
    }

    func load() {
        try? store.ensure()
        pages = store.loadPages(); databases = store.loadDatabases(); plans = store.loadPlans()
        if pages.isEmpty && databases.isEmpty && plans.isEmpty { seedWelcome() }
        if selected == nil { selected = pages.first.map { .page($0.id) } }
        loaded = true; lastDisk = diskStamp()
    }

    private func seedWelcome() {
        var p = Page(title: "Welcome to Antsly", blocks: [
            Block(kind: .text, text: "Pages, databases and plans live in one folder of plain files that you own."),
            Block(kind: .heading, text: "Try this"),
            Block(kind: .todo, text: "Type / on an empty line to change a block"),
            Block(kind: .todo, text: "Add a database or a plan from the + button in the sidebar"),
            Block(kind: .todo, text: "Turn on version history in Settings"),
            Block(kind: .callout, text: "Everything saves automatically.")])
        p.updated = Date().timeIntervalSince1970
        pages = [p]; try? store.save(p)
    }

    /// Picks up changes made outside the app (iCloud, git pull, another editor) when nothing here is waiting to be saved.
    func reloadIfChanged() {
        guard dirtyPages.isEmpty, dirtyDBs.isEmpty, dirtyPlans.isEmpty else { return }
        let s = diskStamp()
        guard s > lastDisk else { return }
        lastDisk = s
        pages = store.loadPages(); databases = store.loadDatabases(); plans = store.loadPlans()
    }

    private func diskStamp() -> Date {
        var latest = Date.distantPast
        for d in [store.pagesDir, store.databasesDir, store.plansDir] {
            for u in (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                if let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > latest { latest = m }
            }
        }
        return latest
    }

    // MARK: Undo and redo

    /// Call before a local change. Changes with the same key within a second share one undo step.
    private func recordUndo(_ key: String) {
        history.record(key: key, state: Snap(pages: pages, databases: databases, plans: plans))
        canUndo = history.canUndo; canRedo = history.canRedo
    }

    func undo() { if let s = history.undo(current: current()) { restore(s) }; canUndo = history.canUndo; canRedo = history.canRedo }
    func redo() { if let s = history.redo(current: current()) { restore(s) }; canUndo = history.canUndo; canRedo = history.canRedo }
    private func current() -> Snap { Snap(pages: pages, databases: databases, plans: plans) }

    private func restore(_ s: Snap) {
        for old in pages where !s.pages.contains(where: { $0.id == old.id }) { store.delete(pageID: old.id); Collab.shared.sendRemoved(old.id) }
        for old in databases where !s.databases.contains(where: { $0.id == old.id }) { store.delete(databaseID: old.id) }
        for old in plans where !s.plans.contains(where: { $0.id == old.id }) { store.delete(planID: old.id) }
        for p in s.pages where pages.first(where: { $0.id == p.id }) != p { dirtyPages.insert(p.id); Collab.shared.send(p) }
        for d in s.databases where databases.first(where: { $0.id == d.id }) != d { dirtyDBs.insert(d.id) }
        for p in s.plans where plans.first(where: { $0.id == p.id }) != p { dirtyPlans.insert(p.id) }
        pages = s.pages; databases = s.databases; plans = s.plans
        if let sel = selected, !exists(sel) { selected = pages.first.map { .page($0.id) } }
        scheduleSave()
    }

    func exists(_ item: Item) -> Bool {
        switch item {
        case .page(let id): pages.contains { $0.id == id }
        case .database(let id): databases.contains { $0.id == id }
        case .plan(let id): plans.contains { $0.id == id }
        }
    }

    // MARK: Editing

    func page(_ id: String) -> Page? { pages.first { $0.id == id } }

    func editPage(_ id: String, broadcast: Bool = true, _ change: (inout Page) -> Void) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        if broadcast { recordUndo("page:\(id):\(pages[i].blocks.count)") }
        let before = pages[i]
        change(&pages[i])
        let now = Date().timeIntervalSince1970
        for j in pages[i].blocks.indices where j >= before.blocks.count || pages[i].blocks[j] != before.blocks.first(where: { $0.id == pages[i].blocks[j].id }) { pages[i].blocks[j].stamp = now }
        for b in before.blocks where !pages[i].blocks.contains(where: { $0.id == b.id }) { deletedBlocks[id, default: []].insert(b.id) }
        pages[i].updated = now
        dirtyPages.insert(id); scheduleSave()
        if broadcast { Collab.shared.send(pages[i]) }
    }

    func editDatabase(_ id: String, _ change: (inout Database) -> Void) {
        guard let i = databases.firstIndex(where: { $0.id == id }) else { return }
        recordUndo("db:\(id):\(databases[i].rows.count):\(databases[i].columns.count)")
        change(&databases[i]); dirtyDBs.insert(id); scheduleSave()
    }

    func editPlan(_ id: String, _ change: (inout Plan) -> Void) {
        guard let i = plans.firstIndex(where: { $0.id == id }) else { return }
        recordUndo("plan:\(id):\(plans[i].tasks.count):\(plans[i].phases.count):\(plans[i].people.count)")
        change(&plans[i]); dirtyPlans.insert(id); scheduleSave()
    }

    /// A guest's or host's edit arriving over the network. Merged block by block, never replaced.
    func mergeRemote(_ remote: Page) {
        if let i = pages.firstIndex(where: { $0.id == remote.id }) {
            pages[i] = PageMerge.merge(local: pages[i], remote: remote, deleted: deletedBlocks[remote.id] ?? [])
        } else { pages.insert(remote, at: 0) }
        dirtyPages.insert(remote.id); scheduleSave()
    }

    /// Puts blocks after `after`, or at the end. An empty text block that is being edited is replaced rather than left behind.
    func insert(_ blocks: [Block], into pageID: String, after: String?) {
        editPage(pageID) { p in
            var at = p.blocks.count
            if let after, let i = p.blocks.firstIndex(where: { $0.id == after }) {
                if p.blocks[i].kind == .text, p.blocks[i].text.isEmpty { p.blocks.remove(at: i); at = i } else { at = i + 1 }
            }
            p.blocks.insert(contentsOf: blocks, at: at)
        }
    }

    /// Copies dropped files and images into the workspace's `assets` folder and returns the blocks that show them.
    func assetBlocks(files: [URL], images: [Data]) -> [Block] {
        var out: [Block] = []
        for u in files {
            do { out.append(WorkspaceStore.assetBlock(for: try store.importAsset(from: u))) } catch { report(error, "Adding \(u.lastPathComponent)") }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        for (n, d) in images.enumerated() {
            do { out.append(WorkspaceStore.assetBlock(for: try store.importAsset(data: d, name: "Image-\(stamp)-\(n + 1).png"))) } catch { report(error, "Adding the image") }
        }
        return out
    }

    /// Replaces blocks made from pasted text with a version your own Claude Code sorted. One undo step brings the old ones back.
    func organiseWithAI(pageID: String, ids: [String], text: String) async {
        do {
            let blocks = try await AIOrganizer.organise(text)
            editPage(pageID) { p in
                guard let first = p.blocks.firstIndex(where: { ids.contains($0.id) }) else { return }
                p.blocks.removeAll { ids.contains($0.id) }
                p.blocks.insert(contentsOf: blocks, at: min(first, p.blocks.count))
            }
            show("Organised with Claude Code.")
        } catch { report(error, "Organising with AI") }
    }

    func removeRemote(pageID: String) { pages.removeAll { $0.id == pageID }; store.delete(pageID: pageID); if selected == .page(pageID) { selected = nil } }

    func newPage() { recordUndo(UUID().uuidString); let p = Page(); pages.insert(p, at: 0); dirtyPages.insert(p.id); selected = .page(p.id); scheduleSave(); Collab.shared.send(p) }
    func newDatabase() { recordUndo(UUID().uuidString); let d = Database.tasks(title: "Untitled database"); databases.append(d); dirtyDBs.insert(d.id); selected = .database(d.id); scheduleSave() }
    func newPlan() {
        recordUndo(UUID().uuidString)
        let ph = Plan.Phase(name: "Phase 1", color: "#2563EB")
        let now = Date()
        let p = Plan(title: "New plan", phases: [ph], people: [Plan.Person(name: NSFullUserName())],
                     tasks: [Plan.Task(phaseID: ph.id, name: "First task", start: now, end: now.addingTimeInterval(86400 * 28))])
        plans.append(p); dirtyPlans.insert(p.id); selected = .plan(p.id); scheduleSave()
    }

    func delete(_ item: Item) {
        recordUndo(UUID().uuidString)
        switch item {
        case .page(let id): pages.removeAll { $0.id == id }; store.delete(pageID: id); Collab.shared.sendRemoved(id)
        case .database(let id): databases.removeAll { $0.id == id }; store.delete(databaseID: id)
        case .plan(let id): plans.removeAll { $0.id == id }; store.delete(planID: id)
        }
        if selected == item { selected = pages.first.map { .page($0.id) } }
    }

    func importGanttMagic(_ url: URL) throws {
        var plan = try GanttMagicImport.parse(Data(contentsOf: url))
        recordUndo(UUID().uuidString)
        plan.title = url.deletingPathExtension().lastPathComponent
        plans.append(plan); dirtyPlans.insert(plan.id); selected = .plan(plan.id); scheduleSave()
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { self?.flush() }
        }
    }

    func flush() {
        saveTask?.cancel()
        for id in dirtyPages { if let p = page(id) { do { try store.save(p) } catch { AppLog.error(error, context: "save page") } } }
        for id in dirtyDBs { if let d = databases.first(where: { $0.id == id }) { do { try store.save(d) } catch { AppLog.error(error, context: "save database") } } }
        for id in dirtyPlans { if let p = plans.first(where: { $0.id == id }) { do { try store.save(PlanMath.snapshotIfDue(p)) } catch { AppLog.error(error, context: "save plan") } } }
        let any = !(dirtyPages.isEmpty && dirtyDBs.isEmpty && dirtyPlans.isEmpty)
        dirtyPages = []; dirtyDBs = []; dirtyPlans = []
        if any { lastDisk = diskStamp() }
    }

    // MARK: Version history and sharing through git

    func refreshHistory() async {
        guard repo.isRepo else { commits = []; remote = nil; return }
        remote = repo.remoteURL
        var path: String?
        if case .page(let id) = selected { path = "pages/\(id).md" }
        commits = await repo.log(path: path)
        if selectedCommit == nil || !commits.contains(where: { $0.id == selectedCommit?.id }) { selectedCommit = commits.first }
        if let c = selectedCommit { diff = await repo.diff(of: c, path: path) } else { diff = [] }
        conflicts = await repo.conflictedFiles()
    }

    func select(commit: Commit) { selectedCommit = commit; Task { await refreshHistory() } }

    func enableHistory() async {
        do { try await repo.initialize(); flush(); try await repo.saveVersion(message: "Start of history") } catch { report(error, "Turning on version history") }
        await refreshHistory()
    }

    /// Commits pending changes, then pulls and pushes when a remote is set. Quiet unless something needs the user.
    func saveVersion(message: String? = nil, manual: Bool = false) async {
        guard repo.isRepo, !gitBusy else { return }
        gitBusy = true; defer { gitBusy = false }
        flush()
        do {
            let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
            let saved = try await repo.saveVersion(message: message ?? "Update \(f.string(from: .now))")
            if saved { lastCommitAt = .now }
            if remote != nil || repo.remoteURL != nil {
                switch try await repo.sync() {
                case .conflicts(let files): conflicts = files; gitNote = "\(files.count) page\(files.count == 1 ? "" : "s") changed on both sides."
                case .offline: gitNote = "Offline. Will share when you are back online."
                case .pulled: gitNote = "Got the latest changes."; pages = store.loadPages(); databases = store.loadDatabases(); plans = store.loadPlans()
                default: gitNote = "Up to date."
                }
            } else if manual { gitNote = saved ? "Version saved." : "Nothing new to save." }
        } catch { report(error, "Saving a version") }
        await refreshHistory()
    }

    func resolve(_ file: String, keepMine: Bool) async {
        do { try await repo.resolve(file, keepMine: keepMine); pages = store.loadPages() } catch { report(error, "Resolving the conflict") }
        await refreshHistory()
    }

    func restore(_ commit: Commit) async {
        guard case .page(let id) = selected else { return }
        do { try await repo.restore(commit, path: "pages/\(id).md"); pages = store.loadPages(); show("Restored that version.") } catch { report(error, "Restoring that version") }
    }

    /// Runs only while the window is open; at most one version every five minutes.
    func autoVersionIfDue() async {
        guard Prefs.shared.historyEnabled, repo.isRepo, Date().timeIntervalSince(lastCommitAt) > 300 else { return }
        await saveVersion()
    }

    func createGitHubRepo() async {
        gitBusy = true; defer { gitBusy = false }
        do {
            if !repo.isRepo { try await repo.initialize() }
            flush(); try await repo.saveVersion(message: "Start of history")
            let name = "antsly-workspace"
            _ = try await Shell.check("gh", ["repo", "create", name, "--private", "--source", ".", "--remote", "origin", "--push"], cwd: store.root, timeout: 90)
            remote = repo.remoteURL; show("Created a private GitHub repository.")
        } catch { report(error, "Creating the GitHub repository") }
        await refreshHistory()
    }

    func connect(remoteURL: String) async {
        do { if !repo.isRepo { try await repo.initialize() }; try await repo.setRemote(remoteURL); remote = repo.remoteURL; await saveVersion(manual: true) } catch { report(error, "Connecting the repository") }
    }

    // MARK: GitHub issues as a database

    func syncIssues() async {
        guard let url = repo.remoteURL ?? remote, let slug = GitHubIssues.repoSlug(fromRemote: url) else { show("Connect a GitHub repository first.", error: true); return }
        do {
            let issues = try await GitHubIssues.fetch(repo: slug)
            let existing = databases.first { $0.source == "github:\(slug)" }
            let db = GitHubIssues.database(repo: slug, issues: issues, existing: existing)
            if let i = databases.firstIndex(where: { $0.id == db.id }) { databases[i] = db } else { databases.append(db) }
            dirtyDBs.insert(db.id); flush(); selected = .database(db.id)
        } catch { report(error, "Fetching GitHub issues") }
    }

    /// A status change made on an issue row goes back to GitHub.
    func pushIssueStatus(databaseID: String, rowID: String, open: Bool) async {
        guard let db = databases.first(where: { $0.id == databaseID }), let src = db.source, src.hasPrefix("github:"), rowID.hasPrefix("gh-"), let n = Int(rowID.dropFirst(3)) else { return }
        do { try await GitHubIssues.setState(repo: String(src.dropFirst(7)), number: n, open: open) } catch { report(error, "Updating the issue on GitHub") }
    }

    // MARK: Cloud sync (iCloud Drive)

    var inICloud: Bool { store.root.path.contains("Mobile Documents") }

    func setICloud(_ on: Bool) {
        flush()
        let target = on ? WorkspaceStore.iCloudRoot : WorkspaceStore.defaultRoot
        guard let target else { show("iCloud Drive is not turned on for this Mac. Turn it on in System Settings, then try again.", error: true); return }
        guard target != store.root else { return }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { show("That folder already has an Antsly workspace. Using it.") }
            else { try FileManager.default.moveItem(at: store.root, to: target) }
            Prefs.shared.workspacePath = target.path
            store = WorkspaceStore(root: target); load(); Task { await refreshHistory() }
            show(on ? "Your workspace now syncs through iCloud Drive." : "Your workspace is back on this Mac only.")
        } catch { report(error, "Moving the workspace") }
    }

    private func report(_ error: Error, _ action: String) {
        AppLog.error(error, context: action)
        AppModel.shared.show(UserError.message(for: error, action: action), error: true)
    }
    private func show(_ m: String, error: Bool = false) { AppModel.shared.show(m, error: error) }
}
