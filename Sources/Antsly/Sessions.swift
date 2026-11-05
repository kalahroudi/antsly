// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AntslyKit

/// What a session holds. EDIT THIS: replace `notes` with the app's real session content (keep it Codable).
struct SessionContent: Codable, Equatable { var notes = "" }

/// Open sessions, shown as stacked rows in the sidebar. Only metadata lives in memory; the selected session's content is loaded
/// on demand and written back (debounced) on every change, on switching, on window close, on deactivate and on quit.
@MainActor @Observable
final class SessionsModel {
    static let shared = SessionsModel()

    private(set) var sessions: [SessionMeta] = []
    private(set) var selected: UUID?
    private(set) var content = SessionContent()      // the selected session only
    var renaming: UUID?

    private let store = SessionStore(directory: AppPaths().sessionsDir)
    private var saveTask: Task<Void, Never>?
    private var dirtyContent = false

    func restore() {
        let loaded = store.load()
        sessions = loaded.index.sessions
        selected = loaded.index.selected.flatMap { id in sessions.contains { $0.id == id } ? id : nil } ?? sessions.first?.id
        if !loaded.quarantined.isEmpty { AppLog.info("sessions: quarantined \(loaded.quarantined)") }
        if loaded.recoveredFromCrash { AppModel.shared.show("Restored \(sessions.count) session\(sessions.count == 1 ? "" : "s") after the app closed unexpectedly") }
        loadContent()
    }

    @discardableResult func add(title: String? = nil) -> UUID {
        flush()
        let meta = SessionMeta(title: title ?? "Session \(sessions.count + 1)")
        sessions.append(meta)
        selected = meta.id; content = SessionContent()
        persistIndex(); Nav.shared.pane = .session
        return meta.id
    }

    func select(_ id: UUID) {
        guard id != selected else { Nav.shared.pane = .session; return }
        flush()
        selected = id; loadContent(); persistIndex(); Nav.shared.pane = .session
    }

    func selectIndex(_ n: Int) { if sessions.indices.contains(n) { select(sessions[n].id) } }

    func close(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if id == selected { flush() }
        sessions.remove(at: i); store.deletePayload(id)
        if id == selected { selected = sessions.indices.contains(i) ? sessions[i].id : sessions.last?.id; loadContent() }
        persistIndex()
        if selected == nil, Nav.shared.pane == .session { Nav.shared.pane = .overview }
    }

    func duplicate(_ id: UUID) {
        guard let m = sessions.first(where: { $0.id == id }) else { return }
        flush()
        let copy = SessionMeta(title: m.title + " copy")
        if let d = store.readPayload(id) { try? store.writePayload(copy.id, d) }
        sessions.append(copy); persistIndex(); select(copy.id)
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { sessions[i].title = t; sessions[i].updatedAt = Date(); persistIndex() }
        renaming = nil
    }

    func setStatus(_ id: UUID, _ status: SessionStatus) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].status != status else { return }
        sessions[i].status = status; persistIndex()      // status is saved at once: it is what recovery looks at
    }

    /// Bind the editor to this. Every change schedules a short-debounced write.
    func update(_ change: (inout SessionContent) -> Void) {
        change(&content); dirtyContent = true
        if let s = selected, let i = sessions.firstIndex(where: { $0.id == s }) { sessions[i].updatedAt = Date() }
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(600)); if !Task.isCancelled { flush() } }
    }

    /// Synchronous and idempotent: safe to call from willTerminate / resign-active / window close.
    func flush() {
        saveTask?.cancel()
        if dirtyContent, let s = selected, let data = try? JSONEncoder().encode(content) {
            do { try store.writePayload(s, data); dirtyContent = false } catch { AppLog.error(error, context: "save session") }
        }
        persistIndex()
    }

    /// Window closed: persist, then drop the content so a closed UI holds no memory (rule 3).
    func releaseContent() { flush(); content = SessionContent() }
    func reloadContentIfNeeded() { if selected != nil, content == SessionContent() { loadContent() } }

    func shutdown() { flush(); store.markCleanShutdown() }

    private func loadContent() {
        guard let s = selected, let data = store.readPayload(s) else { content = SessionContent(); return }
        do { content = try JSONDecoder().decode(SessionContent.self, from: data) }
        catch { AppLog.error(error, context: "read session"); content = SessionContent() }   // never crash on a bad file
    }

    private func persistIndex() {
        var idx = SessionIndex(); idx.sessions = sessions; idx.selected = selected
        do { try store.saveIndex(idx) } catch { AppLog.error(error, context: "save session index") }
    }
}

extension SessionStatus {
    /// Shape + colour, never colour alone.
    var symbol: String { switch self { case .idle: "circle"; case .running: "circle.fill"; case .busy: "circle.dotted"; case .error: "exclamationmark.triangle.fill"; case .interrupted: "arrow.counterclockwise.circle" } }
    var tint: Color { switch self { case .idle: .secondary; case .running: Theme.ok; case .busy: Theme.accent; case .error: Theme.danger; case .interrupted: Theme.warn } }
    var label: String { switch self { case .idle: "Idle"; case .running: "Running"; case .busy: "Working"; case .error: "Needs attention"; case .interrupted: "Interrupted" } }
}

/// Stacked session rows between the primary panes and the footer. Scrolls on its own so Settings/Help stay pinned.
struct SessionsSection: View {
    let sessions = SessionsModel.shared
    let nav = Nav.shared
    let collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if !collapsed { SectionLabel("Sessions") }
                Spacer(minLength: 0)
                Button { sessions.add() } label: { Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("New session (⌘T)").accessibilityLabel("New session")
            }.padding(.horizontal, collapsed ? 0 : 10).frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading).padding(.top, 8)
            ScrollView {
                VStack(spacing: 2) { ForEach(sessions.sessions) { SessionRow(meta: $0, collapsed: collapsed) } }
            }.scrollIndicators(.never)
        }
    }
}

struct SessionRow: View {
    let meta: SessionMeta
    let collapsed: Bool
    let sessions = SessionsModel.shared
    let nav = Nav.shared
    @State private var hover = false
    @State private var draft = ""

    private var on: Bool { sessions.selected == meta.id && nav.pane == .session }

    var body: some View {
        HStack(spacing: 6) {
            // Whole row selects; the close button is a separate control with its own hit area.
            Button { sessions.select(meta.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: meta.status.symbol).font(.system(size: 9)).foregroundStyle(meta.status.tint).frame(width: 20)
                    if !collapsed {
                        if sessions.renaming == meta.id {
                            TextField("Name", text: $draft).textFieldStyle(.plain).font(.system(size: 13)).onSubmit { sessions.rename(meta.id, to: draft) }
                                .onExitCommand { sessions.renaming = nil }
                        } else {
                            Text(meta.title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if !collapsed && (hover || on) {
                Button { sessions.close(meta.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close session").accessibilityLabel("Close \(meta.title)")
            }
        }
        .foregroundStyle(on ? Theme.accent : Color.primary.opacity(0.85))
        .background(on ? Theme.accentSoft : (hover ? Theme.fill : .clear), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) { if on { Capsule().fill(Theme.accent).frame(width: 3, height: 16).offset(x: -1) } }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hover = $0 }
        .help("\(meta.title) · \(meta.status.label)")
        .accessibilityLabel("\(meta.title), \(meta.status.label)")
        .contextMenu {
            Button("Rename") { draft = meta.title; sessions.renaming = meta.id }
            Button("Duplicate") { sessions.duplicate(meta.id) }
            Divider()
            Button("Close") { sessions.close(meta.id) }
        }
    }
}

/// Main pane for the selected session. EDIT THIS: the app's real session UI goes here.
struct SessionPane: View {
    let sessions = SessionsModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: sessions.sessions.first { $0.id == sessions.selected }?.title ?? "Session")
            TextEditor(text: Binding(get: { sessions.content.notes }, set: { v in sessions.update { $0.notes = v } }))
                .font(.system(size: 13)).scrollContentBackground(.hidden).padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 22).padding(.bottom, 22)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
