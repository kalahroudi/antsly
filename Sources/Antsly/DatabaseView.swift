// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AntslyKit

/// A database as a table or a board. Rows from GitHub issues push status changes back to GitHub.
struct DatabaseView: View {
    let id: String
    @State private var mode: Mode = .table
    @State private var newColumn = ""
    @State private var showColumn = false
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
            Button { ws.editDatabase(id) { $0.rows.append(.init()) } } label: { Label("New row", systemImage: "plus") }.buttonStyle(Pill(kind: .primary))
        }
    }

    private func table(_ db: Database) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(db.columns) { c in Text(c.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8) }
                Button { showColumn = true } label: { Image(systemName: "plus").font(.system(size: 11)).frame(width: 28, height: 22).contentShape(Rectangle()) }.buttonStyle(.plain)
                    .popover(isPresented: $showColumn) {
                        HStack { TextField("Column name", text: $newColumn).frame(width: 160).onSubmit(addColumn); Button("Add", action: addColumn).buttonStyle(Pill(kind: .primary)) }.padding(12)
                    }.help("Add a column").accessibilityLabel("Add a column")
            }.padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            StyledScroll {
                VStack(spacing: 0) {
                    ForEach(db.rows) { r in
                        HStack(spacing: 0) {
                            ForEach(db.columns) { c in cell(db, r, c) }
                            Button(role: .destructive) { ws.editDatabase(id) { d in d.rows.removeAll { $0.id == r.id } } } label: { Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 28, height: 22).contentShape(Rectangle()) }
                                .buttonStyle(.plain).help("Delete row").accessibilityLabel("Delete row")
                        }.padding(.horizontal, 14).padding(.vertical, 3)
                        Divider().opacity(0.6)
                    }
                    if db.rows.isEmpty { Text("No rows yet. Add one with New row.").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(20) }
                }
            }
        }
    }

    @ViewBuilder private func cell(_ db: Database, _ r: Database.Row, _ c: Database.Column) -> some View {
        let binding = Binding(get: { r.cells[c.id] ?? "" }, set: { v in ws.editDatabase(id) { d in if let i = d.rows.firstIndex(where: { $0.id == r.id }) { d.rows[i].cells[c.id] = v } } })
        if c.id == db.groupBy, db.source != nil {
            Menu {
                ForEach(["Open", "Closed"], id: \.self) { s in Button(s) { binding.wrappedValue = s; Task { await ws.pushIssueStatus(databaseID: id, rowID: r.id, open: s == "Open") } } }
            } label: { Text(binding.wrappedValue).font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 2)
                .background(binding.wrappedValue == "Open" ? Theme.warnSoft : Theme.fill, in: Capsule()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
        } else {
            TextField("", text: binding).textFieldStyle(.plain).font(.system(size: 13)).padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
                .disabled(db.source != nil && c.id != "owner" && c.id != "labels" ? false : false)
        }
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
