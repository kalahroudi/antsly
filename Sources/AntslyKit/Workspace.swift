// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One block of a page. Blocks have stable ids so collaborators can merge edits block by block.
public struct Block: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case text, heading, todo, bullet, callout, code, image, file
        /// The kinds a text block can be turned into. Images and files are made by dropping them on the page.
        public static let writable: [Kind] = [.text, .heading, .todo, .bullet, .callout, .code]
        public var isAsset: Bool { self == .image || self == .file }
    }
    public var id: String
    public var kind: Kind
    public var text: String
    public var checked: Bool
    public var stamp: Double          // last edit time, used for last-writer-wins merging
    public init(id: String = UUID().uuidString, kind: Kind = .text, text: String = "", checked: Bool = false, stamp: Double = Date().timeIntervalSince1970) {
        self.id = id; self.kind = kind; self.text = text; self.checked = checked; self.stamp = stamp
    }
}

public struct Page: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var title: String
    public var blocks: [Block]
    public var updated: Double
    public init(id: String = UUID().uuidString, title: String = "Untitled", blocks: [Block] = [Block()], updated: Double = Date().timeIntervalSince1970) {
        self.id = id; self.title = title; self.blocks = blocks; self.updated = updated
    }
}

/// Pages are plain Markdown so they diff and merge well in git and open anywhere.
/// First line `# Title`, then one block per paragraph. Block ids live in an HTML comment so edits keep identity.
public enum PageMarkdown {
    public static func render(_ page: Page) -> String {
        var out = "<!-- antsly:\(page.id) -->\n# \(page.title)\n\n"
        for b in page.blocks {
            let tag = "<!--b:\(b.id)-->"
            switch b.kind {
            case .text: out += "\(b.text) \(tag)\n\n"
            case .heading: out += "## \(b.text) \(tag)\n\n"
            case .todo: out += "- [\(b.checked ? "x" : " ")] \(b.text) \(tag)\n\n"
            case .bullet: out += "- \(b.text) \(tag)\n\n"
            case .callout: out += "> \(b.text) \(tag)\n\n"
            case .code: out += "```\n\(b.text)\n``` \(tag)\n\n"
            case .image: out += "![\((b.text as NSString).lastPathComponent)](\(b.text)) \(tag)\n\n"
            case .file: out += "[\((b.text as NSString).lastPathComponent)](\(b.text)) \(tag)\n\n"
            }
        }
        return out
    }

    public static func parse(_ md: String, fallbackID: String, updated: Double) -> Page {
        var id = fallbackID, title = "Untitled", blocks: [Block] = []
        var lines = md.components(separatedBy: "\n")[...]
        if let f = lines.first, f.hasPrefix("<!-- antsly:"), let r = f.range(of: "-->") {
            id = String(f.dropFirst(12)[..<f.index(f.startIndex, offsetBy: f.distance(from: f.startIndex, to: r.lowerBound))]).trimmingCharacters(in: .whitespaces)
            lines = lines.dropFirst()
        }
        if let f = lines.first(where: { !$0.isEmpty }), f.hasPrefix("# ") { title = String(f.dropFirst(2)); lines = lines.drop(while: { $0 != f }).dropFirst() }

        func split(_ s: String) -> (String, String?) {
            guard let r = s.range(of: "<!--b:", options: .backwards), s.hasSuffix("-->") else { return (s, nil) }
            let bid = String(s[r.upperBound...].dropLast(3))
            return (String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), bid)
        }
        /// `![name](assets/x.png)` is an image and `[name](assets/x.pdf)` a file; the path is all a block keeps.
        func asset(_ t: String, image: Bool) -> String? {
            guard t.hasPrefix(image ? "![" : "["), t.hasSuffix(")"), let r = t.range(of: "](assets/") else { return nil }
            return String(t[t.index(after: r.lowerBound)...].dropFirst().dropLast())
        }
        var i = lines.startIndex
        while i < lines.endIndex {
            let line = lines[i]
            if line.isEmpty { i += 1; continue }
            if line.hasPrefix("```") {
                var body: [String] = []; i += 1
                var bid: String?
                while i < lines.endIndex, !lines[i].hasPrefix("```") { body.append(lines[i]); i += 1 }
                if i < lines.endIndex { bid = split(lines[i]).1 }
                i += 1
                blocks.append(Block(id: bid ?? UUID().uuidString, kind: .code, text: body.joined(separator: "\n"), stamp: updated))
                continue
            }
            var (text, bid) = split(line)
            var kind = Block.Kind.text, checked = false
            if let path = asset(text, image: true) { kind = .image; text = path }
            else if let path = asset(text, image: false) { kind = .file; text = path }
            else if text.hasPrefix("## ") { kind = .heading; text = String(text.dropFirst(3)) }
            else if text.hasPrefix("- [x] ") { kind = .todo; checked = true; text = String(text.dropFirst(6)) }
            else if text.hasPrefix("- [ ] ") { kind = .todo; text = String(text.dropFirst(6)) }
            else if text.hasPrefix("- ") { kind = .bullet; text = String(text.dropFirst(2)) }
            else if text.hasPrefix("> ") { kind = .callout; text = String(text.dropFirst(2)) }
            blocks.append(Block(id: bid ?? UUID().uuidString, kind: kind, text: text, checked: checked, stamp: updated))
            i += 1
        }
        if blocks.isEmpty { blocks = [Block(stamp: updated)] }
        return Page(id: id, title: title, blocks: blocks, updated: updated)
    }
}

/// What a column holds. Cells are always stored as strings so the JSON stays simple and hand-editable:
/// dates as `yyyy-MM-dd`, checkboxes as "true" or "", everything else as typed.
public enum ColumnKind: String, Codable, Sendable, CaseIterable {
    case text, number, status, select, date, person, checkbox, url

    public var label: String {
        switch self {
        case .text: "Text"
        case .number: "Number"
        case .status: "Status"
        case .select: "Choice"
        case .date: "Date"
        case .person: "Person"
        case .checkbox: "Checkbox"
        case .url: "Link"
        }
    }
    /// Columns made before types existed carry no kind. The id of the standard ones says what they are.
    static func infer(id: String) -> ColumnKind {
        switch id {
        case "status": .status
        case "owner", "assignee": .person
        case "due", "start", "end", "date": .date
        default: .text
        }
    }
    public var defaultOptions: [String] { self == .status ? ["Not started", "In progress", "Blocked", "Done"] : [] }
}

/// How a status label is drawn. Matching is by common words so standard labels get a colour without setup.
public enum StatusTone: Sendable { case neutral, active, blocked, done
    public static func of(_ value: String) -> StatusTone {
        let v = value.lowercased()
        if v.isEmpty { return .neutral }
        if ["done", "closed", "complete", "completed", "shipped", "resolved"].contains(where: v.contains) { return .done }
        if ["block", "stuck", "failed", "cancel"].contains(where: v.contains) { return .blocked }
        if ["progress", "open", "doing", "review", "active"].contains(where: v.contains) { return .active }
        return .neutral
    }
}

/// Date cells are stored as plain `yyyy-MM-dd` so they sort and diff as text.
public enum CellDate {
    private static func formatter() -> DateFormatter {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }
    public static func parse(_ s: String) -> Date? { s.isEmpty ? nil : formatter().date(from: s) }
    public static func format(_ d: Date) -> String { formatter().string(from: d) }
}

/// A database: typed columns and rows, stored as JSON next to the pages. Issues from GitHub use the same shape.
public struct Database: Identifiable, Equatable, Codable, Sendable {
    public struct Column: Equatable, Codable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var kind: ColumnKind
        public var options: [String]       // labels for status and choice columns, people for person columns
        public init(id: String, name: String, kind: ColumnKind? = nil, options: [String]? = nil) {
            let k = kind ?? ColumnKind.infer(id: id)
            self.id = id; self.name = name; self.kind = k; self.options = options ?? k.defaultOptions
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let id = try c.decode(String.self, forKey: .id)
            self.init(id: id, name: try c.decode(String.self, forKey: .name), kind: try c.decodeIfPresent(ColumnKind.self, forKey: .kind),
                      options: try c.decodeIfPresent([String].self, forKey: .options))
        }
    }
    public struct Row: Equatable, Codable, Sendable, Identifiable { public var id: String; public var cells: [String: String]
        public init(id: String = UUID().uuidString, cells: [String: String] = [:]) { self.id = id; self.cells = cells } }
    public var id: String
    public var title: String
    public var columns: [Column]
    public var rows: [Row]
    public var groupBy: String?        // column id whose values form board lanes
    public var source: String?         // "github:owner/repo" when rows mirror GitHub issues
    public init(id: String = UUID().uuidString, title: String, columns: [Column], rows: [Row] = [], groupBy: String? = nil, source: String? = nil) {
        self.id = id; self.title = title; self.columns = columns; self.rows = rows; self.groupBy = groupBy; self.source = source
    }
    public static func tasks(title: String = "Tasks") -> Database {
        Database(title: title, columns: [.init(id: "name", name: "Task"), .init(id: "status", name: "Status"), .init(id: "owner", name: "Owner"), .init(id: "due", name: "Due")], groupBy: "status")
    }
    public var lanes: [String] {
        guard let g = groupBy else { return [] }
        var seen: [String] = []
        for r in rows { let v = r.cells[g] ?? ""; if !seen.contains(v) { seen.append(v) } }
        return seen
    }

    /// The values a status, choice or person cell can take: the configured ones, plus anything already used in the rows.
    public func choices(for column: Column) -> [String] {
        var out = column.options
        for r in rows { let v = r.cells[column.id] ?? ""; if !v.isEmpty, !out.contains(v) { out.append(v) } }
        return out
    }

    // Group actions. Both leave rows that are not named untouched.
    public mutating func removeRows(_ ids: Set<String>) { rows.removeAll { ids.contains($0.id) } }
    public mutating func setCells(_ ids: Set<String>, column: String, to value: String) {
        for i in rows.indices where ids.contains(rows[i].id) { rows[i].cells[column] = value }
    }
}

/// Ready-made instructions for an AI agent that can use Antsly, built from the rows the user picked.
/// The user pastes one into their agent; nothing is sent from the app.
public enum AgentTask: String, CaseIterable, Sendable, Identifiable {
    case investigate, fix, schedule, summarize
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .investigate: "Investigate"
        case .fix: "Fix"
        case .schedule: "Schedule"
        case .summarize: "Summarize"
        }
    }
    var instruction: String {
        switch self {
        case .investigate: "Investigate each item below: find out what is going on, what is blocking it and what the next step is. Write your findings in the Notes column if there is one, otherwise report them back to me."
        case .fix: "Fix each item below if it is something you can do in this project. Make the change, then set its status to Done. Tell me what you changed and anything you could not do."
        case .schedule: "Suggest a realistic order and due date for each item below, based on its status and anything blocking it. Fill the due date column with dates as yyyy-MM-dd and explain your reasoning briefly."
        case .summarize: "Summarize the items below in a few sentences: what is done, what is in progress, what is stuck. Do not change anything."
        }
    }

    public func prompt(for db: Database, rows: [Database.Row], file: String) -> String {
        let header = db.columns.map(\.name).joined(separator: " | ")
        let lines = rows.map { r in db.columns.map { r.cells[$0.id] ?? "" }.joined(separator: " | ") }
        return """
        \(instruction)

        Database "\(db.title)" (\(file)). Columns: \(header)

        \(lines.joined(separator: "\n"))

        The database is a plain JSON file. Edit rows by id only: \(rows.map(\.id).joined(separator: ", ")). Keep every other row as it is, and never delete a row.
        """
    }

    public static func stylePrompt(for db: Database, file: String) -> String {
        let cols = db.columns.map { "\($0.id) (\($0.name), \($0.kind.rawValue))" }.joined(separator: ", ")
        let sample = db.rows.prefix(15).map { r in db.columns.map { r.cells[$0.id] ?? "" }.joined(separator: " | ") }.joined(separator: "\n")
        return """
        Improve how the database "\(db.title)" looks and reads, by editing its column settings in \(file). Do not change any row.
        For each column choose a "kind" from: \(ColumnKind.allCases.map(\.rawValue).joined(separator: ", ")). For status, choice and person columns set "options" to a sensible list of labels or people, in the order they should appear. Rename columns only if the new name is clearly clearer. Put the most important columns first.

        Columns now: \(cols)

        First rows:
        \(sample)
        """
    }
}

/// Reads and writes one workspace folder. All writes are atomic (temp file + rename).
public final class WorkspaceStore: @unchecked Sendable {
    public let root: URL
    public var pagesDir: URL { root.appendingPathComponent("pages", isDirectory: true) }
    public var databasesDir: URL { root.appendingPathComponent("databases", isDirectory: true) }
    public var plansDir: URL { root.appendingPathComponent("plans", isDirectory: true) }
    public var assetsDir: URL { root.appendingPathComponent("assets", isDirectory: true) }

    public init(root: URL) { self.root = root }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Antsly", isDirectory: true)
    }
    /// The iCloud Drive folder, if the user is signed in to iCloud Drive.
    public static var iCloudRoot: URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return base.appendingPathComponent("Antsly", isDirectory: true)
    }

    public func ensure() throws {
        for d in [root, pagesDir, databasesDir, plansDir] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    private func write(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) }
        else { try FileManager.default.moveItem(at: tmp, to: url) }
    }

    public func pageURL(_ id: String) -> URL { pagesDir.appendingPathComponent("\(id).md") }

    public func save(_ page: Page) throws {
        try ensure()
        try write(Data(PageMarkdown.render(page).utf8), to: pageURL(page.id))
    }

    public func loadPages() -> [Page] {
        let files = (try? FileManager.default.contentsOfDirectory(at: pagesDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap { u in
            guard let md = try? String(contentsOf: u, encoding: .utf8) else { return nil }
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            return PageMarkdown.parse(md, fallbackID: u.deletingPathExtension().lastPathComponent, updated: m)
        }.sorted { $0.updated > $1.updated }
    }

    // MARK: Assets

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

    /// File names are kept readable but made safe for a Markdown link: letters, digits, dot, dash and underscore.
    static func safeName(_ name: String) -> String {
        let cleaned = String(name.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
        return cleaned.isEmpty ? "file" : cleaned
    }

    /// Copies a dropped file into `assets/` and returns its path relative to the workspace. Never overwrites: a taken name gets a number.
    public func importAsset(from url: URL) throws -> String { try importAsset(named: url.lastPathComponent) { try FileManager.default.copyItem(at: url, to: $0) } }
    public func importAsset(data: Data, name: String) throws -> String { try importAsset(named: name) { try data.write(to: $0) } }

    private func importAsset(named name: String, write: (URL) throws -> Void) throws -> String {
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let safe = Self.safeName(name), ext = (safe as NSString).pathExtension, stem = (safe as NSString).deletingPathExtension
        var candidate = safe, n = 2
        while FileManager.default.fileExists(atPath: assetsDir.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"; n += 1
        }
        try write(assetsDir.appendingPathComponent(candidate))
        return "assets/\(candidate)"
    }

    public func assetURL(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    /// The block that shows an imported asset: an image inline, anything else as a file row.
    public static func assetBlock(for relative: String) -> Block {
        Block(kind: imageExtensions.contains((relative as NSString).pathExtension.lowercased()) ? .image : .file, text: relative)
    }

    public func delete(pageID: String) { try? FileManager.default.removeItem(at: pageURL(pageID)) }

    public func save(_ db: Database) throws {
        try ensure()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(try enc.encode(db), to: databasesDir.appendingPathComponent("\(db.id).json"))
    }

    public func loadDatabases() -> [Database] {
        let files = (try? FileManager.default.contentsOfDirectory(at: databasesDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(Database.self, from: Data(contentsOf: $0)) }
            .sorted { $0.title < $1.title }
    }

    private static var planEncoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }
    public func save(_ plan: Plan) throws {
        try ensure()
        try write(try Self.planEncoder.encode(plan), to: plansDir.appendingPathComponent("\(plan.id).json"))
    }
    public func loadPlans() -> [Plan] {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: plansDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? d.decode(Plan.self, from: Data(contentsOf: $0)) }.sorted { $0.title < $1.title }
    }
    public func delete(planID: String) { try? FileManager.default.removeItem(at: plansDir.appendingPathComponent("\(planID).json")) }

    public func delete(databaseID: String) { try? FileManager.default.removeItem(at: databasesDir.appendingPathComponent("\(databaseID).json")) }

    /// Case-insensitive search over titles and block text. Plain scan: workspaces are small and this runs only on demand.
    public static func search(_ query: String, in pages: [Page]) -> [Page] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return pages.filter { $0.title.lowercased().contains(q) || $0.blocks.contains { $0.text.lowercased().contains(q) } }
    }
}
