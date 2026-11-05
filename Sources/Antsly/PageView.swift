// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AntslyKit

/// One page: a block editor, and a history view with diffs and restore.
struct PageView: View {
    let id: String
    @State private var mode: Mode = .edit
    @FocusState private var focus: String?
    let ws = WorkspaceModel.shared
    let collab = Collab.shared
    enum Mode: Hashable { case edit, history }

    private var readOnly: Bool { if case .joined("view") = collab.joinState { true } else { false } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if mode == .edit { editor } else { HistoryView(pageID: id) }
        }
        .onChange(of: focus) { _, new in collab.sendPresence(pageID: id, blockID: new) }
        .onDisappear { ws.flush(); collab.sendPresence(pageID: id, blockID: nil) }
    }

    private var header: some View {
        PaneHeader(title: "", subtitle: nil, trailing: {
            HStack(spacing: 10) {
                ForEach(Array((collab.presence[id] ?? [:]).keys.sorted()), id: \.self) { n in
                    Text(String(n.prefix(1))).font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22)
                        .background(Theme.accentSoft, in: Circle()).foregroundStyle(Theme.accent).help("\(n) is here")
                }
                Segmented(options: [(Mode.edit, "Edit"), (Mode.history, "History")], selection: $mode)
            }
        }, tabs: { EmptyView() })
        .overlay(alignment: .leading) {
            TextField("Untitled", text: Binding(get: { ws.page(id)?.title ?? "" }, set: { v in ws.editPage(id) { $0.title = v } }))
                .textFieldStyle(.plain).font(.system(size: 19, weight: .semibold)).padding(.leading, 22).padding(.top, 26).padding(.trailing, 240)
                .disabled(readOnly)
        }
    }

    private var editor: some View {
        StyledScroll {
            VStack(alignment: .leading, spacing: 2) {
                if let p = ws.page(id) {
                    ForEach(p.blocks) { b in
                        BlockRow(pageID: id, blockID: b.id, focus: $focus, readOnly: readOnly).id(b.id)
                    }
                }
                if !readOnly {
                    Button { addBlock(after: nil) } label: { Label("Add a block", systemImage: "plus").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8).contentShape(Rectangle()) }
                        .buttonStyle(.plain).padding(.leading, 30)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            .frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func addBlock(after blockID: String?) {
        let nb = Block()
        ws.editPage(id) { p in
            if let blockID, let i = p.blocks.firstIndex(where: { $0.id == blockID }) { p.blocks.insert(nb, at: i + 1) } else { p.blocks.append(nb) }
        }
        focus = nb.id
    }
}

struct BlockRow: View {
    let pageID: String
    let blockID: String
    var focus: FocusState<String?>.Binding
    var readOnly: Bool
    let ws = WorkspaceModel.shared
    let collab = Collab.shared
    @State private var hover = false
    @State private var confirmDelete = false

    private var block: Block? { ws.page(pageID)?.blocks.first { $0.id == blockID } }
    private var slash: Bool { (block?.text ?? "").hasPrefix("/") }
    private var others: [String] { (collab.presence[pageID] ?? [:]).filter { $0.value == blockID }.map(\.key).sorted() }

    var body: some View {
        if let b = block {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    handle(b)
                    lead(b)
                    TextField("Type / for blocks", text: Binding(get: { block?.text ?? "" }, set: { v in ws.editPage(pageID) { p in if let i = p.blocks.firstIndex(where: { $0.id == blockID }) { p.blocks[i].text = v } } }), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(font(b.kind))
                        .foregroundStyle(b.kind == .todo && b.checked ? Color.secondary : Color.primary)
                        .strikethrough(b.kind == .todo && b.checked)
                        .focused(focus, equals: blockID)
                        .disabled(readOnly)
                        .onSubmit { addAfter(b) }
                        .onKeyPress(.delete) { if b.text.isEmpty, (ws.page(pageID)?.blocks.count ?? 0) > 1 { remove(); return .handled }; return .ignored }
                    ForEach(others, id: \.self) { n in
                        Text(n).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.accent, in: Capsule()).foregroundStyle(Theme.onAccent)
                    }
                }
                .padding(.vertical, b.kind == .heading ? 6 : 2)
                .padding(.horizontal, b.kind == .callout ? 10 : 0)
                .background(b.kind == .callout ? Theme.accentSoft : (b.kind == .code ? Theme.fill : .clear), in: RoundedRectangle(cornerRadius: 8))
                if slash && !readOnly { slashMenu(b) }
            }
            .onHover { hover = $0 }
        }
    }

    @ViewBuilder private func lead(_ b: Block) -> some View {
        switch b.kind {
        case .todo:
            Button { ws.editPage(pageID) { p in if let i = p.blocks.firstIndex(where: { $0.id == blockID }) { p.blocks[i].checked.toggle() } } } label: {
                Image(systemName: b.checked ? "checkmark.square.fill" : "square").foregroundStyle(b.checked ? Theme.accent : .secondary).font(.system(size: 15))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(readOnly).accessibilityLabel(b.checked ? "Mark not done" : "Mark done")
        case .bullet: Text("•").foregroundStyle(.secondary).frame(width: 16)
        case .callout: Image(systemName: "lightbulb").foregroundStyle(Theme.accent).font(.system(size: 13))
        default: EmptyView()
        }
    }

    private func handle(_ b: Block) -> some View {
        Menu {
            ForEach(Block.Kind.allCases, id: \.self) { k in Button(label(k)) { setKind(k) } }
            Divider()
            Button("Delete block…", role: .destructive) { confirmDelete = true }
        } label: { Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 18, height: 22).contentShape(Rectangle()) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().opacity(hover && !readOnly ? 1 : 0).help("Change block type")
            .confirmationDialog("Delete this block?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { remove() }
                Button("Cancel", role: .cancel) {}
            }
    }

    private func slashMenu(_ b: Block) -> some View {
        let q = String(b.text.dropFirst()).lowercased()
        let kinds = Block.Kind.allCases.filter { q.isEmpty || label($0).lowercased().contains(q) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(kinds, id: \.self) { k in
                Button { setKind(k, clear: true) } label: { Text(label(k)).font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 5).contentShape(Rectangle()) }.buttonStyle(.plain)
            }
        }.frame(width: 200).background(Theme.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline)).padding(.leading, 30).padding(.top, 2)
    }

    private func label(_ k: Block.Kind) -> String { switch k { case .text: "Text"; case .heading: "Heading"; case .todo: "To-do"; case .bullet: "Bullet"; case .callout: "Callout"; case .code: "Code" } }
    private func font(_ k: Block.Kind) -> Font {
        switch k { case .heading: .system(size: 20, weight: .semibold); case .code: .system(size: 12.5, design: .monospaced); default: .system(size: 14) }
    }
    private func setKind(_ k: Block.Kind, clear: Bool = false) {
        ws.editPage(pageID) { p in if let i = p.blocks.firstIndex(where: { $0.id == blockID }) { p.blocks[i].kind = k; if clear { p.blocks[i].text = "" } } }
        focus.wrappedValue = blockID
    }
    private func addAfter(_ b: Block) {
        let kind: Block.Kind = (b.kind == .todo || b.kind == .bullet) && !b.text.isEmpty ? b.kind : .text
        let nb = Block(kind: kind)
        ws.editPage(pageID) { p in if let i = p.blocks.firstIndex(where: { $0.id == blockID }) { p.blocks.insert(nb, at: i + 1) } }
        focus.wrappedValue = nb.id
    }
    private func remove() {
        var prev: String?
        ws.editPage(pageID) { p in
            guard let i = p.blocks.firstIndex(where: { $0.id == blockID }) else { return }
            prev = i > 0 ? p.blocks[i - 1].id : (p.blocks.count > 1 ? p.blocks[1].id : nil)
            p.blocks.remove(at: i)
        }
        focus.wrappedValue = prev
    }
}

/// Versions of this page, what changed in each, restore, and conflicts that need a decision.
struct HistoryView: View {
    let pageID: String
    let ws = WorkspaceModel.shared
    let prefs = Prefs.shared

    var body: some View {
        Group {
            if !ws.repo.isRepo { enable }
            else {
                HStack(alignment: .top, spacing: 0) {
                    list.frame(width: 250)
                    Divider()
                    detail
                }
            }
        }
        .task { await ws.refreshHistory() }
    }

    private var enable: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text("Keep a history of every change").font(.system(size: 15, weight: .semibold))
            Text("Antsly saves versions of your workspace with git, so you can see what changed and go back. It stays on this Mac until you share it.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Turn on version history") { prefs.historyEnabled = true; Task { await ws.enableHistory() } }.buttonStyle(Pill(kind: .primary))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("Versions")
                Spacer()
                Button { Task { await ws.saveVersion(manual: true) } } label: { HStack(spacing: 5) { if ws.gitBusy { ProgressView().controlSize(.mini) }; Text("Save version") } }
                    .buttonStyle(Pill(kind: .primary)).disabled(ws.gitBusy)
            }.padding(.horizontal, 14).padding(.top, 12)
            if !ws.gitNote.isEmpty { Text(ws.gitNote).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.horizontal, 14) }
            StyledScroll {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ws.commits) { c in
                        let on = ws.selectedCommit?.id == c.id
                        Button { ws.select(commit: c) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.subject).font(.system(size: 12.5, weight: on ? .semibold : .regular)).lineLimit(1)
                                Text("\(c.author) · \(c.date.formatted(.relative(presentation: .named)))").font(.system(size: 11)).foregroundStyle(.secondary)
                            }.padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                                .background(on ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                    if ws.commits.isEmpty { Text("No versions of this page yet.").font(.system(size: 12)).foregroundStyle(.secondary).padding(10) }
                }.padding(.horizontal, 8)
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !ws.conflicts.isEmpty { conflicts }
            HStack {
                SectionLabel("Changes")
                Spacer()
                if let c = ws.selectedCommit { Button("Restore this version") { Task { await ws.restore(c) } }.buttonStyle(Pill()) }
            }
            StyledScroll {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ws.diff.enumerated()), id: \.offset) { _, l in
                        if l.kind != .header {
                            Text((l.kind == .added ? "+ " : l.kind == .removed ? "− " : "  ") + l.text.replacingOccurrences(of: #"\s*<!--b:[^>]*-->"#, with: "", options: .regularExpression))
                                .font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 1)
                                .foregroundStyle(l.kind == .added ? Theme.ok : l.kind == .removed ? Theme.danger : Color.secondary)
                                .background(l.kind == .added ? Theme.ok.opacity(0.1) : l.kind == .removed ? Theme.danger.opacity(0.1) : .clear)
                        }
                    }
                    if ws.diff.isEmpty { Text("Pick a version to see what changed.").font(.system(size: 12)).foregroundStyle(.secondary).padding(10) }
                }.background(Theme.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var conflicts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Changed on both sides").font(.system(size: 13, weight: .semibold))
            Text("You and someone else edited the same page. Choose which version to keep for each page.").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(ws.conflicts, id: \.self) { f in
                HStack {
                    Text(f).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Button("Keep mine") { Task { await ws.resolve(f, keepMine: true) } }.buttonStyle(Pill())
                    Button("Keep theirs") { Task { await ws.resolve(f, keepMine: false) } }.buttonStyle(Pill())
                }
            }
        }.padding(12).background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 10))
    }
}
