// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AntslyKit

/// A database as a table or a board. Rows from GitHub issues push status changes back to GitHub.
struct DatabaseView: View {
    let id: String
    @State private var mode: Mode = .table
    @State private var newColumn = ""
    @State private var showColumn = false
    @State private var selection = Set<String>()
    @State private var confirmDelete = false
    @State private var dropColumn: Database.Column?
    @State private var pendingRows = Set<String>()      // rows waiting for the delete confirmation
    let ws = WorkspaceModel.shared
    enum Mode: Hashable { case table, board }

    private var db: Database? { ws.databases.first { $0.id == id } }

    var body: some View {
        if let db {
            VStack(spacing: 0) {
                PaneHeader(title: "", subtitle: nil, trailing: { controls(db) }, tabs: { EmptyView() })
                    .overlay(alignment: .leading) {
                        VStack(alignment: .leading, spacing: 1) {
                            TextField("Untitled database", text: Binding(get: { db.title }, set: { v in ws.editDatabase(id) { $0.title = v } })).textFieldStyle(.plain).font(.system(size: 19, weight: .semibold))
                            if let s = db.source { Text("Connected to github.com/\(s.dropFirst(7))").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                        }.padding(.leading, 22).padding(.top, 26).padding(.trailing, 320)
                    }
                if mode == .table { table(db) } else { board(db) }
            }
        }
    }

    @ViewBuilder private func controls(_ db: Database) -> some View {
        HStack(spacing: 10) {
            Segmented(options: [(Mode.table, "Table"), (Mode.board, "Board")], selection: $mode)
            if db.source != nil { Button { Task { await ws.syncIssues() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(Pill()) }
            Button { handOff(AgentTask.stylePrompt(for: db, file: file(db)), "Styling prompt") } label: { Label("Style with AI", systemImage: "sparkles") }.buttonStyle(Pill()).help("Copy a prompt that asks your AI agent to set column types and labels")
            Button { ws.editDatabase(id) { $0.rows.append(.init()) } } label: { Label("New row", systemImage: "plus") }.buttonStyle(Pill(kind: .primary))
        }
    }

    private func table(_ db: Database) -> some View {
        let allOn = !db.rows.isEmpty && selection.count == db.rows.count
        return VStack(spacing: 0) {
            if !selection.isEmpty { bulkBar(db) }
            HStack(spacing: 0) {
                checkbox(allOn) { selection = allOn ? [] : Set(db.rows.map(\.id)) }.help("Select all").accessibilityLabel("Select all rows")
                ForEach(db.columns) { c in columnHeader(db, c) }
                Button { showColumn = true } label: { Image(systemName: "plus").font(.system(size: 11)).frame(width: 28, height: 22).contentShape(Rectangle()) }.buttonStyle(.plain)
                    .popover(isPresented: $showColumn) {
                        HStack { TextField("Column name", text: $newColumn).frame(width: 160).onSubmit(addColumn); Button("Add", action: addColumn).buttonStyle(Pill(kind: .primary)) }.padding(12)
                    }.help("Add a column").accessibilityLabel("Add a column")
                Color.clear.frame(width: 28 + 28 + 28, height: 1)
            }.padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            StyledScroll {
                VStack(spacing: 0) {
                    ForEach(db.rows) { r in
                        HStack(spacing: 0) {
                            checkbox(selection.contains(r.id)) { if !selection.insert(r.id).inserted { selection.remove(r.id) } }.accessibilityLabel("Select row")
                            ForEach(db.columns) { c in cell(db, r, c) }
                            ReminderButton(title: r.cells[db.columns.first?.id ?? "name"] ?? "", target: .init(kind: .row, a: id, b: r.id), compact: true).frame(width: 28)
                            rowMenu(db, r)
                            Button(role: .destructive) { pendingRows = [r.id]; confirmDelete = true } label: { Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 28, height: 22).contentShape(Rectangle()) }
                                .buttonStyle(.plain).help("Delete row").accessibilityLabel("Delete row")
                        }.padding(.horizontal, 14).padding(.vertical, 3)
                            .background(selection.contains(r.id) ? Theme.accentSoft : .clear)
                        Divider().opacity(0.6)
                    }
                    if db.rows.isEmpty { Text("No rows yet. Add one with New row.").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(20) }
                }
            }
        }
        .confirmationDialog("Delete \(pendingRows.count) row\(pendingRows.count == 1 ? "" : "s")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { ws.editDatabase(id) { $0.removeRows(pendingRows) }; selection.subtract(pendingRows); pendingRows = [] }
            Button("Cancel", role: .cancel) { pendingRows = [] }
        } message: { Text("You can undo this with Edit, Undo.") }
        .confirmationDialog("Delete the \(dropColumn?.name ?? "") column?", isPresented: Binding(get: { dropColumn != nil }, set: { if !$0 { dropColumn = nil } }), titleVisibility: .visible) {
            Button("Delete column", role: .destructive) { if let c = dropColumn { ws.editDatabase(id) { d in d.columns.removeAll { $0.id == c.id }; for i in d.rows.indices { d.rows[i].cells[c.id] = nil } } }; dropColumn = nil }
            Button("Cancel", role: .cancel) { dropColumn = nil }
        } message: { Text("Its values are removed from every row.") }
    }

    private func checkbox(_ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 14)).foregroundStyle(on ? Theme.accent : .secondary).frame(width: 28, height: 22).contentShape(Rectangle()) }.buttonStyle(.plain)
    }

    private func columnHeader(_ db: Database, _ c: Database.Column) -> some View {
        Menu {
            Menu("Type") { ForEach(ColumnKind.allCases, id: \.self) { k in Button((c.kind == k ? "✓ " : "") + k.label) { setKind(c, k) } } }
            if c.kind == .status || c.kind == .select || c.kind == .person {
                Divider()
                Text(c.kind == .person ? "People" : "Labels")
                ForEach(c.options, id: \.self) { o in Button("Remove \(o)") { ws.editDatabase(id) { d in if let i = d.columns.firstIndex(where: { $0.id == c.id }) { d.columns[i].options.removeAll { $0 == o } } } } }
            }
            Divider()
            Button("Delete column…", role: .destructive) { dropColumn = c }
        } label: { Text(c.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).help("Column type and options")
    }

    private func setKind(_ c: Database.Column, _ k: ColumnKind) {
        ws.editDatabase(id) { d in
            guard let i = d.columns.firstIndex(where: { $0.id == c.id }) else { return }
            d.columns[i].kind = k
            if d.columns[i].options.isEmpty { d.columns[i].options = k.defaultOptions }
        }
    }

    /// Appears once rows are ticked: change one column for all of them, ask an agent about them, or delete them.
    private func bulkBar(_ db: Database) -> some View {
        let picks = db.columns.filter { [.status, .select, .person, .checkbox].contains($0.kind) }
        return HStack(spacing: 10) {
            Text("\(selection.count) selected").font(.system(size: 12.5, weight: .semibold))
            ForEach(picks) { c in
                Menu("Set \(c.name)") {
                    if c.kind == .checkbox { Button("Checked") { setSelected(c, "true") }; Button("Unchecked") { setSelected(c, "") } }
                    else { ForEach(db.choices(for: c), id: \.self) { v in Button(v) { setSelected(c, v, push: c.id == db.groupBy) } }; Divider(); Button("Clear") { setSelected(c, "") } }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            ForEach(db.columns.filter { $0.kind == .date }) { c in
                Menu("Set \(c.name)") {
                    Button("Today") { setSelected(c, CellDate.format(.now)) }
                    Button("In a week") { setSelected(c, CellDate.format(.now.addingTimeInterval(7 * 86400))) }
                    Button("Clear") { setSelected(c, "") }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            agentMenu(db, rowIDs: selection)
            Spacer()
            Button { pendingRows = selection; confirmDelete = true } label: { Label("Delete", systemImage: "trash") }.buttonStyle(Pill(kind: .danger))
            Button("Clear selection") { selection = [] }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.vertical, 8).background(Theme.fill)
    }

    private func setSelected(_ c: Database.Column, _ value: String, push: Bool = false) {
        let ids = selection
        ws.editDatabase(id) { $0.setCells(ids, column: c.id, to: value) }
        if push, ws.databases.first(where: { $0.id == id })?.source != nil { for rid in ids { Task { await ws.pushIssueStatus(databaseID: id, rowID: rid, open: value == "Open") } } }
    }

    private func agentMenu(_ db: Database, rowIDs: Set<String>) -> some View {
        Menu {
            ForEach(AgentTask.allCases) { t in
                Button(t.label) { handOff(t.prompt(for: db, rows: db.rows.filter { rowIDs.contains($0.id) }, file: file(db)), "\(t.label) prompt") }
            }
        } label: { Label("Ask agent", systemImage: "sparkles") }.menuStyle(.borderlessButton).fixedSize().help("Copy a prompt for your AI agent")
    }

    private func rowMenu(_ db: Database, _ r: Database.Row) -> some View {
        agentMenu(db, rowIDs: [r.id]).labelStyle(.iconOnly).frame(width: 28)
    }

    private func file(_ db: Database) -> String { "databases/\(db.id).json" }

    /// The prompt goes to the clipboard; the user pastes it into whichever agent they use.
    private func handOff(_ prompt: String, _ what: String) {
        Clipboard.copy(prompt)
        AppModel.shared.show("\(what) copied. Paste it into your AI agent.")
    }

    @ViewBuilder private func cell(_ db: Database, _ r: Database.Row, _ c: Database.Column) -> some View {
        let binding = Binding(get: { r.cells[c.id] ?? "" }, set: { v in ws.editDatabase(id) { d in if let i = d.rows.firstIndex(where: { $0.id == r.id }) { d.rows[i].cells[c.id] = v } } })
        let pushes = c.id == db.groupBy && db.source != nil
        switch c.kind {
        case .status, .select:
            choiceMenu(db, c, binding.wrappedValue, status: c.kind == .status) { v in binding.wrappedValue = v; if pushes { Task { await ws.pushIssueStatus(databaseID: id, rowID: r.id, open: v == "Open") } } }
        case .person:
            choiceMenu(db, c, binding.wrappedValue, status: false, allowNew: true) { binding.wrappedValue = $0 }
        case .date:
            HStack(spacing: 4) {
                DatePicker("", selection: Binding(get: { CellDate.parse(binding.wrappedValue) ?? .now }, set: { binding.wrappedValue = CellDate.format($0) }), displayedComponents: .date).labelsHidden().datePickerStyle(.compact)
                    .opacity(binding.wrappedValue.isEmpty ? 0.35 : 1).help(binding.wrappedValue.isEmpty ? "Pick a date" : "Change the date")
                if !binding.wrappedValue.isEmpty { Button { binding.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("Clear date") }
                Spacer(minLength: 0)
            }.padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
        case .checkbox:
            Button { binding.wrappedValue = binding.wrappedValue.isEmpty ? "true" : "" } label: {
                Image(systemName: binding.wrappedValue.isEmpty ? "square" : "checkmark.square.fill").foregroundStyle(binding.wrappedValue.isEmpty ? Color.secondary : Theme.accent).font(.system(size: 14))
            }.buttonStyle(.plain).padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel(c.name)
        case .number, .url, .text:
            HStack(spacing: 4) {
                TextField("", text: binding).textFieldStyle(.plain).font(.system(size: 13, design: c.kind == .number ? .monospaced : .default)).multilineTextAlignment(c.kind == .number ? .trailing : .leading)
                if c.kind == .url, let u = URL(string: binding.wrappedValue), u.scheme?.hasPrefix("http") == true { Link(destination: u) { Image(systemName: "arrow.up.right.square") }.foregroundStyle(Theme.accent) }
            }.padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A pre-rendered label (status, choice) or a person from the list, with a way to add one more.
    private func choiceMenu(_ db: Database, _ c: Database.Column, _ value: String, status: Bool, allowNew: Bool = false, set: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(db.choices(for: c), id: \.self) { v in Button(v) { set(v) } }
            if !value.isEmpty { Divider(); Button("Clear") { set("") } }
            if allowNew || c.kind == .select || c.kind == .status {
                Divider()
                Button("Add \(c.kind == .person ? "a person" : "a label")…") { addOption(to: c, then: set) }
            }
        } label: {
            Group {
                if value.isEmpty { Text("—").foregroundStyle(.tertiary) }
                else if status { Text(value).font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 2).background(tone(StatusTone.of(value)).0, in: Capsule()).foregroundStyle(tone(StatusTone.of(value)).1) }
                else if c.kind == .person { Label(value, systemImage: "person.circle.fill").font(.system(size: 12.5)) }
                else { Text(value).font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 2).background(Theme.fill, in: Capsule()) }
            }
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
    }

    private func tone(_ t: StatusTone) -> (Color, Color) {
        switch t {
        case .done: (Theme.ok.opacity(0.16), Theme.ok)
        case .blocked: (Theme.dangerSoft, Theme.danger)
        case .active: (Theme.warnSoft, Theme.warn)
        case .neutral: (Theme.fill, .secondary)
        }
    }

    /// Asks for the new label in a small alert-style panel, adds it to the column and applies it to the cell.
    private func addOption(to c: Database.Column, then set: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = c.kind == .person ? "Add a person" : "Add a label"
        alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces); guard !v.isEmpty else { return }
        ws.editDatabase(id) { d in if let i = d.columns.firstIndex(where: { $0.id == c.id }), !d.columns[i].options.contains(v) { d.columns[i].options.append(v) } }
        set(v)
    }

    private func board(_ db: Database) -> some View {
        let key = db.groupBy ?? db.columns.dropFirst().first?.id ?? "status"
        let lanes = db.lanes.isEmpty ? ["No status"] : db.lanes
        return HStack(alignment: .top, spacing: 12) {
            ForEach(lanes, id: \.self) { lane in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(lane.isEmpty ? "No status" : lane) · \(db.rows.filter { ($0.cells[key] ?? "") == lane }.count)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    StyledScroll {
                        VStack(spacing: 8) {
                            ForEach(db.rows.filter { ($0.cells[key] ?? "") == lane }) { r in
                                Text(r.cells[db.columns.first?.id ?? "name"] ?? "").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).card(padding: 10)
                                    .contextMenu {
                                        ForEach(lanes.filter { $0 != lane }, id: \.self) { l in
                                            Button("Move to \(l.isEmpty ? "No status" : l)") {
                                                ws.editDatabase(id) { d in if let i = d.rows.firstIndex(where: { $0.id == r.id }) { d.rows[i].cells[key] = l } }
                                                if db.source != nil { Task { await ws.pushIssueStatus(databaseID: id, rowID: r.id, open: l == "Open") } }
                                            }
                                        }
                                    }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }.padding(16)
    }

    private func addColumn() {
        let n = newColumn.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        ws.editDatabase(id) { $0.columns.append(.init(id: UUID().uuidString, name: n)) }
        newColumn = ""; showColumn = false
    }
}
