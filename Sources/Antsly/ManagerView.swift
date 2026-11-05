// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AntslyKit

/// Panes of the Manager window. Pages, databases and plans share the `workspace` pane; what shows is the sidebar selection.
enum Pane: String, CaseIterable, Identifiable {
    case workspace, today, sharing, settings, help
    var id: String { rawValue }
    var title: String { switch self { case .workspace: "Workspace"; case .today: "Today"; case .sharing: "Sharing"; case .settings: "Settings"; case .help: "Help" } }
    var symbol: String { switch self { case .workspace: "doc.text"; case .today: "calendar"; case .sharing: "person.2.wave.2"; case .settings: "gearshape"; case .help: "questionmark.circle" } }
}

@MainActor @Observable
final class Nav {
    static let shared = Nav()
    var pane: Pane = .workspace
    var planTab: PlanView.Tab = .timeline
    var reportResources = false      // screenshots only: open the report on its Resources view

    // Back and forward through where you have been: mouse buttons 4 and 5, Cmd-[ and Cmd-], and the chevrons in the sidebar.
    struct Place: Equatable { var pane: Pane; var item: WorkspaceModel.Item? }
    private(set) var history: [Place] = []
    private(set) var index = -1
    @ObservationIgnored private var moving = false
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < history.count - 1 }

    /// Called whenever the pane or the selection changes.
    func record() {
        guard !moving else { return }
        let here = Place(pane: pane, item: pane == .workspace ? WorkspaceModel.shared.selected : nil)
        if index >= 0, history[index] == here { return }
        history = Array(history.prefix(index + 1)) + [here]
        if history.count > 100 { history.removeFirst() }
        index = history.count - 1
    }
    func back() { step(-1) }
    func forward() { step(1) }
    private func step(_ d: Int) {
        var i = index + d
        // Skip places whose page, database or plan has since been deleted.
        while history.indices.contains(i), let it = history[i].item, !WorkspaceModel.shared.exists(it) { i += d }
        guard history.indices.contains(i) else { return }
        moving = true; index = i
        pane = history[i].pane
        if let it = history[i].item { WorkspaceModel.shared.selected = it }
        moving = false
    }
}

/// The Manager window: a fixed sidebar (collapsible to icons) and a main pane that uses the full width.
struct ManagerView: View {
    var agentsTab = false
    let model = AppModel.shared
    let nav = Nav.shared
    let ws = WorkspaceModel.shared

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            Divider()
            ZStack {
                Theme.pane
                VStack(spacing: 0) {
                    if let t = model.runningTask { TaskBanner(task: t) }
                    detail
                }
            }
            .overlay(alignment: .bottom) { ToastView() }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 900, minHeight: 620)
        .onAppear { model.setManagerVisible(true); nav.record() }
        .onChange(of: nav.pane) { _, _ in nav.record() }
        .onChange(of: ws.selected) { _, _ in nav.record() }
    }

    @ViewBuilder private var detail: some View {
        if !model.loadedOnce || !ws.loaded {
            SkeletonList(rows: 9).frame(maxHeight: .infinity, alignment: .top).padding(.top, 40)   // never show a half-loaded page
        } else if model.needsSetup && nav.pane == .workspace {
            SetupView().padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 40)
        } else {
            switch nav.pane {
            case .workspace: WorkspaceDetail()
            case .today: TodayView()
            case .sharing: SharingPane()
            case .settings: SettingsPane(initialTab: agentsTab ? .agents : .general)
            case .help: HelpPane()
            }
        }
    }
}

struct WorkspaceDetail: View {
    let ws = WorkspaceModel.shared
    var body: some View {
        switch ws.selected {
        case .page(let id)?: PageView(id: id).id(id)
        case .database(let id)?: DatabaseView(id: id).id(id)
        case .plan(let id)?: PlanView(id: id).id(id)
        case nil:
            VStack(spacing: 12) {
                Image(nsImage: AppIcon.image(size: 72)).resizable().frame(width: 72, height: 72)
                Text("Nothing open").font(.system(size: 16, weight: .semibold))
                Text("Pick something in the sidebar, or start a new page.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                Button("New page") { ws.newPage() }.buttonStyle(Pill(kind: .primary))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct Sidebar: View {
    let nav = Nav.shared
    let prefs = Prefs.shared
    let ws = WorkspaceModel.shared
    let collab = Collab.shared
    var collapsed: Bool { prefs.sidebarCollapsed }
    @State private var pendingDelete: WorkspaceModel.Item?

    private func name(of item: WorkspaceModel.Item) -> String {
        switch item {
        case .page(let id): ws.page(id)?.title ?? "this page"
        case .database(let id): ws.databases.first { $0.id == id }?.title ?? "this database"
        case .plan(let id): ws.plans.first { $0.id == id }?.title ?? "this plan"
        }
    }

    var body: some View {
        content.confirmationDialog("Delete \(pendingDelete.map(name(of:)) ?? "")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let i = pendingDelete { ws.delete(i) }; pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("You can undo this with Edit, Undo.") }
    }

    @ViewBuilder private var content: some View {
        @Bindable var w = ws
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if !collapsed {
                    Button { nav.back() } label: { Image(systemName: "chevron.left").frame(width: 22, height: 24).contentShape(Rectangle()) }
                        .buttonStyle(.plain).foregroundStyle(nav.canGoBack ? Color.primary : Color.secondary.opacity(0.4)).disabled(!nav.canGoBack).help("Back").accessibilityLabel("Back")
                    Button { nav.forward() } label: { Image(systemName: "chevron.right").frame(width: 22, height: 24).contentShape(Rectangle()) }
                        .buttonStyle(.plain).foregroundStyle(nav.canGoForward ? Color.primary : Color.secondary.opacity(0.4)).disabled(!nav.canGoForward).help("Forward").accessibilityLabel("Forward")
                    Menu {
                        Button("New page", systemImage: "doc.badge.plus") { ws.newPage(); nav.pane = .workspace }
                        Button("New database", systemImage: "tablecells.badge.ellipsis") { ws.newDatabase(); nav.pane = .workspace }
                        Button("New plan", systemImage: "chart.bar.xaxis") { ws.newPlan(); nav.pane = .workspace }
                        Divider()
                        Button("Import Gantt Magic backup…", systemImage: "square.and.arrow.down") { importGantt() }
                    } label: { Image(systemName: "plus.circle.fill").font(.system(size: 17)).foregroundStyle(Theme.accent) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("New page, database or plan").accessibilityLabel("New")
                }
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.18)) { prefs.sidebarCollapsed.toggle() } } label: {
                    Image(systemName: "sidebar.left").foregroundStyle(.secondary)
                }.buttonStyle(.plain).help(collapsed ? "Expand sidebar" : "Collapse to icons").accessibilityLabel(collapsed ? "Expand sidebar" : "Collapse sidebar")
            }.padding(.top, 14).padding(.bottom, 8).padding(.horizontal, collapsed ? 0 : 6)
            if !collapsed { SearchBox(prompt: "Search pages", text: $w.query).padding(.bottom, 6) }
            item(.today).padding(.bottom, 4)
            StyledScroll {
                VStack(alignment: .leading, spacing: 2) {
                    if !ws.query.isEmpty && !collapsed { results } else { lists }
                }
            }
            Spacer(minLength: 4)
            ForEach([Pane.sharing, .settings, .help]) { item($0) }
            if !collapsed {
                HStack(spacing: 6) {
                    if collab.peopleOnline > 0 { StatusDot(color: Theme.ok); Text("\(collab.peopleOnline) online") }
                    Spacer(); Text("\(AppMemory.footprint)")
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 6).help("Antsly memory use")
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 12)
        .padding(.top, 20)   // room for the traffic lights
        .frame(width: collapsed ? 62 : 212)
        .background(Theme.sidebar)
    }

    @ViewBuilder private var results: some View {
        SectionLabel("Results").padding(.leading, 4)
        ForEach(ws.searchResults) { p in row(.page(p.id), "doc.text", p.title) }
        if ws.searchResults.isEmpty { Text("No pages match.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6) }
    }

    @ViewBuilder private var lists: some View {
        if !collapsed { SectionLabel("Pages").padding(.leading, 4).padding(.top, 2) }
        ForEach(ws.pages) { p in row(.page(p.id), "doc.text", p.title.isEmpty ? "Untitled" : p.title) }
        if !ws.databases.isEmpty {
            if !collapsed { SectionLabel("Databases").padding(.leading, 4).padding(.top, 8) }
            ForEach(ws.databases) { d in row(.database(d.id), d.source != nil ? "ladybug" : "tablecells", d.title) }
        }
        if !ws.plans.isEmpty {
            if !collapsed { SectionLabel("Plans").padding(.leading, 4).padding(.top, 8) }
            ForEach(ws.plans) { p in row(.plan(p.id), "chart.bar.xaxis", p.title) }
        }
    }

    private func row(_ item: WorkspaceModel.Item, _ symbol: String, _ title: String) -> some View {
        let on = nav.pane == .workspace && ws.selected == item
        return Button { ws.selected = item; nav.pane = .workspace } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 20)
                if !collapsed { Text(title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1).truncationMode(.tail); Spacer(minLength: 4) }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .foregroundStyle(on ? Theme.accent : Color.primary.opacity(0.85))
            .background(on ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))   // whole row, including padding, is the click target
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
        .contextMenu { Button("Delete…", role: .destructive) { pendingDelete = item } }
    }

    private func item(_ p: Pane) -> some View {
        let on = nav.pane == p
        return Button { nav.pane = p } label: {
            HStack(spacing: 9) {
                Image(systemName: p.symbol).font(.system(size: 14)).frame(width: 20)
                if !collapsed {
                    Text(p.title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    if p == .settings, Updater.shared.available != nil { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
                    if p == .today { let n = TodayPlan.build(pages: [], databases: ws.databases, plans: ws.plans, reminders: ws.reminders).badge; if n > 0 { Text("\(n)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(on ? Theme.accent : .secondary) } }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .foregroundStyle(on ? Theme.accent : Color.primary.opacity(0.85))
            .background(on ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).help(p.title).accessibilityLabel(p.title)
    }

    private func importGantt() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.message = "Choose a Gantt Magic backup (.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ws.importGanttMagic(url); nav.pane = .workspace } catch {
            AppLog.error(error, context: "import Gantt Magic")
            AppModel.shared.show("That file is not a Gantt Magic backup.", error: true)
        }
    }
}

/// Plain-language help and a glossary.
struct HelpPane: View {
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Help")
            StyledScroll {
                VStack(alignment: .leading, spacing: 14) {
                    topic("What is Antsly?", "One place for notes, documents, wikis, databases and project plans. Everything is a plain file in a folder you own.")
                    topic("Workspace folder", "Pages are Markdown files, databases and plans are JSON files. You can open them in any editor, back them up or put them in git.")
                    topic("Version history", "Antsly saves versions of your workspace with git. Open a page and choose History to see what changed and restore an older version.")
                    topic("Cloud sync", "Turn it on in Settings to keep the workspace in iCloud Drive so it appears on your other Macs.")
                    topic("Live collaboration", "Share a workspace with people on your Tailscale network. They join with a link and you approve them once.")
                    topic("Capacity and allocation", "Each person has days per week of capacity. Each task gives them an allocation in days per week. Over 100% means overloaded.")
                    topic("Burnup", "A chart of total scope against work completed over time. When the lines meet, the plan is done.")
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func topic(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).font(.system(size: 13.5, weight: .semibold))
            Text(d).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: 620, alignment: .leading)
    }
}
