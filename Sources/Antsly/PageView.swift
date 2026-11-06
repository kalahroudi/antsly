// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AntslyKit

/// One page: a block editor, and a history view with diffs and restore.
struct PageView: View {
    let id: String
    @State private var mode: Mode = .edit
    @FocusState private var focus: String?
    @State private var targeted = false
    @State private var ingested: Ingested?       // the last pasted or dropped text, so it can be handed to AI
    @State private var organising = false
    let ws = WorkspaceModel.shared
    let collab = Collab.shared
    enum Mode: Hashable { case edit, history }
    struct Ingested: Equatable { var text: String; var ids: [String] }

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
                if mode == .edit && !readOnly {
                    Button { pasteAndOrganise() } label: { Image(systemName: "doc.on.clipboard") }.buttonStyle(Pill())
                        .keyboardShortcut("v", modifiers: [.command, .shift]).help("Paste and organise (Shift-Command-V)").accessibilityLabel("Paste and organise")
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
                if let ing = ingested { banner(ing) }
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
        .onDrop(of: [.fileURL, .image, .html, .plainText], isTargeted: $targeted) { drop($0) }
        .overlay { if targeted && !readOnly { RoundedRectangle(cornerRadius: 10).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6])).padding(6).allowsHitTesting(false) } }
    }

    // MARK: Drop and paste

    private func banner(_ ing: Ingested) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            Text("Sorted into \(ing.ids.count) blocks").font(.system(size: 12.5))
            Spacer()
            if organising { ProgressView().controlSize(.small) }
            Button("Organise with AI") {
                organising = true
                Task { await ws.organiseWithAI(pageID: id, ids: ing.ids, text: ing.text); organising = false; ingested = nil }
            }.buttonStyle(Pill()).disabled(organising || !AIOrganizer.available).help(AIOrganizer.available ? "Ask your Claude Code to sort this text again. The text is sent to it." : "Needs Claude Code installed")
            Button { ingested = nil } label: { Image(systemName: "xmark").frame(width: 22, height: 22).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Dismiss")
        }.padding(.horizontal, 12).padding(.vertical, 8).background(Theme.fill, in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 8)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard !readOnly else { return false }
        Task { @MainActor in
            var texts: [String] = [], files: [URL] = [], images: [Data] = []
            for p in providers {
                if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let u = await Self.loadFileURL(p) { files.append(u) }
                else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier), let d = await Self.loadImage(p) { images.append(d) }
                else if p.hasItemConformingToTypeIdentifier(UTType.html.identifier), let h = await Self.loadHTML(p), let md = RichPaste.markdown(fromHTML: h) { texts.append(md) }
                else if p.canLoadObject(ofClass: NSString.self), let t = await Self.loadString(p) { texts.append(t) }
            }
            ingest(text: texts.isEmpty ? nil : texts.joined(separator: "\n\n"), files: files, images: images)
        }
        return true
    }

    private func pasteAndOrganise() {
        let pb = NSPasteboard.general
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let html = pb.string(forType: .html).flatMap { RichPaste.markdown(fromHTML: $0) }
        let text = urls.isEmpty ? (html ?? pb.string(forType: .string)) : nil
        var images: [Data] = []
        if urls.isEmpty, text == nil, let img = NSImage(pasteboard: pb), let png = Self.png(img) { images = [png] }
        if urls.isEmpty, text == nil, images.isEmpty { AppModel.shared.show("Nothing to paste.", error: true); return }
        ingest(text: text, files: urls, images: images)
    }

    /// Text becomes sorted blocks, files and images are copied into the workspace. All of it lands after the block being edited.
    private func ingest(text: String?, files: [URL], images: [Data]) {
        var blocks: [Block] = [], textIDs: [String] = []
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { let b = ContentOrganizer.blocks(from: text); textIDs = b.map(\.id); blocks += b }
        blocks += ws.assetBlocks(files: files, images: images)
        guard !blocks.isEmpty else { return }
        ws.insert(blocks, into: id, after: focus)
        focus = blocks.last?.id
        ingested = textIDs.count > 1 || (text?.count ?? 0) > 200 ? Ingested(text: text ?? "", ids: textIDs) : nil
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let t = image.tiffRepresentation, let rep = NSBitmapImageRep(data: t) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
    private static func loadFileURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { c in
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let d = item as? Data { c.resume(returning: URL(dataRepresentation: d, relativeTo: nil)) } else { c.resume(returning: item as? URL) }
            }
        }
    }
    private static func loadImage(_ p: NSItemProvider) async -> Data? {
        let data: Data? = await withCheckedContinuation { c in p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { d, _ in c.resume(returning: d) } }
        return data.flatMap { NSImage(data: $0) }.flatMap(png)
    }
    private static func loadHTML(_ p: NSItemProvider) async -> String? {
        let data: Data? = await withCheckedContinuation { c in p.loadDataRepresentation(forTypeIdentifier: UTType.html.identifier) { d, _ in c.resume(returning: d) } }
        return data.map { String(decoding: $0, as: UTF8.self) }
    }
    private static func loadString(_ p: NSItemProvider) async -> String? {
        await withCheckedContinuation { c in _ = p.loadObject(ofClass: NSString.self) { o, _ in c.resume(returning: o as? String) } }
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
    @State private var editing = false      // a tap on rendered text switches that block to its Markdown source
    @State private var sel: Range<Int>?     // the characters selected in this block, when the system lets us see them

    private var block: Block? { ws.page(pageID)?.blocks.first { $0.id == blockID } }
    private var slash: Bool { (block?.text ?? "").hasPrefix("/") }
    private var others: [String] { (collab.presence[pageID] ?? [:]).filter { $0.value == blockID }.map(\.key).sorted() }

    var body: some View {
        if let b = block {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    handle(b)
                    lead(b)
                    if b.kind.isAsset { AssetBlock(block: b) }
                    else if showsRendered(b) { rendered(b) }
                    else { editor(b) }
                    if !b.text.isEmpty, !readOnly || !ws.reminders(for: reminderTarget).isEmpty { ReminderButton(title: reminderTitle(b), target: reminderTarget).opacity(hover || !ws.reminders(for: reminderTarget).isEmpty ? 1 : 0) }
                    ForEach(others, id: \.self) { n in
                        Text(n).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.accent, in: Capsule()).foregroundStyle(Theme.onAccent)
                    }
                }
                .padding(.vertical, b.kind == .heading ? 6 : 2)
                .padding(.horizontal, b.kind == .callout ? 10 : (b.kind == .code ? 10 : 0))
                .overlay(alignment: .topTrailing) { if b.kind == .code && hover { CopyButton(text: b.text, label: "Copy code").padding(6) } }
                .background(b.kind == .callout ? Theme.accentSoft : (b.kind == .code ? Theme.fill : .clear), in: RoundedRectangle(cornerRadius: 8))
                if slash && !readOnly { slashMenu(b) }
            }
            .overlay(alignment: .bottomLeading) { if let r = sel, focus.wrappedValue == blockID, !readOnly { selectionBar(b, r).offset(x: 28, y: 42) } }
            .zIndex(sel != nil ? 5 : 0)
            .onHover { hover = $0 }
            .onChange(of: focus.wrappedValue) { _, new in if new != blockID { editing = false; sel = nil } }
        }
    }

    /// Formatted text when the block is not being edited. Empty blocks and code stay as editable fields.
    private func showsRendered(_ b: Block) -> Bool {
        guard b.kind != .code, !b.text.isEmpty, InlineMarkdown.hasMarkup(b.text) || readOnly else { return false }
        return readOnly || (!editing && focus.wrappedValue != blockID)
    }

    private func painted(_ text: String) -> AttributedString {
        var (t, marks) = InlineMarkdown.highlighted(text)
        for m in marks {
            let from = t.index(t.startIndex, offsetByCharacters: m.lowerBound), to = t.index(t.startIndex, offsetByCharacters: m.upperBound)
            t[from..<to].backgroundColor = Theme.highlight
        }
        return t
    }

    private func rendered(_ b: Block) -> some View {
        Text(painted(b.text)).font(font(b.kind))
            .foregroundStyle(b.kind == .todo && b.checked ? Color.secondary : Color.primary)
            .strikethrough(b.kind == .todo && b.checked)
            .tint(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .onTapGesture { if !readOnly { editing = true } }
            .help(readOnly ? "" : "Click to edit")
    }

    // MARK: Editing, selection and reminders

    private var reminderTarget: Reminder.Target { .init(kind: .block, a: pageID, b: blockID) }
    private func reminderTitle(_ b: Block) -> String { InlineMarkdown.plain(b.text) }

    @ViewBuilder private func editor(_ b: Block) -> some View {
        let text = Binding(get: { block?.text ?? "" }, set: { v in ws.editPage(pageID) { p in if let i = p.blocks.firstIndex(where: { $0.id == blockID }) { p.blocks[i].text = v } } })
        if #available(macOS 15, *) {
            SelectableField(text: text, onSelection: { sel = $0 }) { styled($0, b) }
        } else {
            styled(TextField("Type / for blocks", text: text, axis: .vertical), b)
        }
    }

    private func styled<V: View>(_ field: V, _ b: Block) -> some View {
        field.textFieldStyle(.plain)
            .font(font(b.kind))
            .foregroundStyle(b.kind == .todo && b.checked ? Color.secondary : Color.primary)
            .strikethrough(b.kind == .todo && b.checked)
            .focused(focus, equals: blockID)
            .onAppear { if editing { focus.wrappedValue = blockID } }
            .disabled(readOnly)
            .onSubmit { addAfter(b) }
            .onKeyPress(.delete) { if b.text.isEmpty, (ws.page(pageID)?.blocks.count ?? 0) > 1 { remove(); return .handled }; return .ignored }
    }

    private func selectedText(_ b: Block, _ r: Range<Int>) -> String {
        guard r.upperBound <= b.text.count else { return "" }
        let a = b.text.index(b.text.startIndex, offsetBy: r.lowerBound), z = b.text.index(b.text.startIndex, offsetBy: r.upperBound)
        return String(b.text[a..<z])
    }

    /// Appears under a selection: highlight it, set a reminder from it, schedule it, or ask an AI about it.
    private func selectionBar(_ b: Block, _ r: Range<Int>) -> some View {
        let chosen = selectedText(b, r)
        return HStack(spacing: 2) {
            barButton("Highlight", icon: "highlighter") { ws.editPage(pageID) { p in if let i = p.blocks.firstIndex(where: { $0.id == blockID }) { p.blocks[i].text = InlineMarkdown.toggleHighlight(in: p.blocks[i].text, range: r) } }; sel = nil }
            ReminderButton(title: InlineMarkdown.plain(chosen), target: reminderTarget, label: "Remind me").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.accent)
            ReminderButton(title: InlineMarkdown.plain(chosen), target: reminderTarget, startWithPicker: true, label: "Schedule")
            Divider().frame(height: 16).padding(.horizontal, 3)
            barButton("Ask AI", icon: "sparkles") {
                Clipboard.copy("Here is a passage from my Antsly page \"\(ws.page(pageID)?.title ?? "")\":\n\n\(chosen)\n\nTell me what I should do about it, and when.")
                AppModel.shared.show("Prompt copied. Paste it into your AI agent.")
            }
        }.padding(4).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline.opacity(2)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3).fixedSize()
    }

    private func barButton(_ title: String, icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.system(size: 12.5)).padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle()) }.buttonStyle(.plain)
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
            if !(block?.kind.isAsset ?? false) { ForEach(Block.Kind.writable, id: \.self) { k in Button(label(k)) { setKind(k) } }; Divider() }
            if !(block?.kind.isAsset ?? false), !(block?.text.isEmpty ?? true) {
                Button((block?.text.hasPrefix("==") ?? false) ? "Remove highlight" : "Highlight block") {
                    ws.editPage(pageID) { p in if let i = p.blocks.firstIndex(where: { $0.id == blockID }) { p.blocks[i].text = InlineMarkdown.toggleHighlight(in: p.blocks[i].text, range: 0..<p.blocks[i].text.count) } }
                }
                Divider()
            }
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
        let kinds = Block.Kind.writable.filter { q.isEmpty || label($0).lowercased().contains(q) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(kinds, id: \.self) { k in
                Button { setKind(k, clear: true) } label: { Text(label(k)).font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 5).contentShape(Rectangle()) }.buttonStyle(.plain)
            }
        }.frame(width: 200).background(Theme.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline)).padding(.leading, 30).padding(.top, 2)
    }

    private func label(_ k: Block.Kind) -> String { switch k { case .text: "Text"; case .heading: "Heading"; case .todo: "To-do"; case .bullet: "Bullet"; case .callout: "Callout"; case .code: "Code"; case .image: "Image"; case .file: "File" } }
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

/// A text field that reports which characters are selected. Needs macOS 15; on older systems the block menu highlights the whole block.
@available(macOS 15, *)
struct SelectableField<Decorated: View>: View {
    @Binding var text: String
    var onSelection: (Range<Int>?) -> Void
    var decorate: (TextField<Text>) -> Decorated
    @State private var selection: TextSelection?
    @State private var editedAt = Date.distantPast

    var body: some View {
        decorate(TextField("Type / for blocks", text: $text, selection: $selection, axis: .vertical))
            .onChange(of: selection) { _, _ in settle() }
            .onChange(of: text) { _, _ in
                // A paste or edit changes the text and the selection together, and the two can arrive out of step.
                // Indices are only safe to read once the text has stopped changing, so drop them and wait.
                editedAt = Date()
                onSelection(nil)
            }
    }

    /// Reads the selection once the text has been quiet for a moment. The selection binding is only a trigger:
    /// its indices trap when read against some strings (long pastes), so the range comes from the AppKit text view instead.
    private func settle() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard Date().timeIntervalSince(editedAt) > 0.2 else { return }
            onSelection(range())
        }
    }

    private func range() -> Range<Int>? {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.string == text else { return nil }
        let ns = tv.selectedRange()
        guard ns.length > 0, let r = Range(ns, in: text) else { return nil }
        let lo = text.distance(from: text.startIndex, to: r.lowerBound), hi = text.distance(from: text.startIndex, to: r.upperBound)
        return hi > lo ? lo..<hi : nil
    }
}

/// An image shown inline, or a file as a row you can open. The block keeps only the path inside the workspace.
struct AssetBlock: View {
    let block: Block
    @State private var image: NSImage?
    private var url: URL { WorkspaceModel.shared.store.assetURL(block.text) }
    private var name: String { (block.text as NSString).lastPathComponent }

    var body: some View {
        Group {
            if !FileManager.default.fileExists(atPath: url.path) {
                Label("\(name) is not in this workspace", systemImage: "exclamationmark.triangle").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.vertical, 4)
            } else if block.kind == .image, let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 360).clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { NSWorkspace.shared.open(url) }.help("Open \(name)").accessibilityLabel(name)
            } else if block.kind == .image {
                ProgressView().controlSize(.small).frame(height: 40)
            } else {
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(Pill())
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder").frame(width: 22, height: 22).contentShape(Rectangle()) }.buttonStyle(.plain).help("Show in Finder").accessibilityLabel("Show in Finder")
                }.card(padding: 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: block.text) { if block.kind == .image { image = NSImage(contentsOf: url) } }
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
