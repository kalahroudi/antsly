// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import AntslyKit

/// `Antsly --snapshot <dir>` renders the app's screens to PNG files for the docs, then exits.
/// It uses made-up sample data, never the user's real data. Add a Shot per screen/theme you want in the README.
enum SnapshotMode {
    nonisolated(unsafe) static var dir: String?

    @MainActor static func run() {
        guard let dir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.accessory)
        Demo.install()
        Task { @MainActor in
            for shot in shots { await render(shot, to: dir) }
            NSApp.terminate(nil)
        }
    }

    struct Shot { let name: String; let dark: Bool; let size: CGSize; let make: @MainActor () -> AnyView }

    @MainActor static var shots: [Shot] {
        func manager(_ p: Pane, dark: Bool = false, agents: Bool = false) -> Shot {
            Shot(name: "manager-\(p.rawValue)\(agents ? "-agents" : "")\(dark ? "-dark" : "")", dark: dark, size: CGSize(width: 1240, height: 800)) {
                Nav.shared.pane = p
                return AnyView(ManagerView(agentsTab: agents))
            }
        }
        func pop(dark: Bool = false) -> Shot {
            Shot(name: "popover\(dark ? "-dark" : "")", dark: dark, size: CGSize(width: 800, height: 600)) { AnyView(PopoverShot()) }
        }
        func page(dark: Bool = false) -> Shot { Shot(name: "page\(dark ? "-dark" : "")", dark: dark, size: CGSize(width: 1240, height: 800)) { WorkspaceModel.shared.selected = .page("launch"); Nav.shared.pane = .workspace; return AnyView(ManagerView()) } }
        func db() -> Shot { Shot(name: "database", dark: false, size: CGSize(width: 1240, height: 800)) { WorkspaceModel.shared.selected = .database(WorkspaceModel.shared.databases[0].id); Nav.shared.pane = .workspace; return AnyView(ManagerView()) } }
        func plan(_ tab: PlanView.Tab, _ name: String, dark: Bool = false, resources: Bool = false) -> Shot {
            Shot(name: "plan-\(name)\(dark ? "-dark" : "")", dark: dark, size: CGSize(width: 1240, height: 800)) {
                WorkspaceModel.shared.selected = .plan(WorkspaceModel.shared.plans[0].id); Nav.shared.pane = .workspace; Nav.shared.planTab = tab; Nav.shared.reportResources = resources; return AnyView(ManagerView()) }
        }
        func share() -> Shot { Shot(name: "sharing", dark: false, size: CGSize(width: 1240, height: 800)) { Nav.shared.pane = .sharing; return AnyView(ManagerView()) } }
        return [page(), page(dark: true), db(), plan(.timeline, "timeline"), plan(.timeline, "timeline", dark: true), plan(.workload, "workload"), plan(.report, "report"), plan(.report, "resources", resources: true), share(), pop(), pop(dark: true), manager(.settings), manager(.help)]
    }

    @MainActor static func render(_ shot: Shot, to dir: String) async {
        let host = NSHostingView(rootView: shot.make().frame(width: shot.size.width, height: shot.size.height))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: shot.size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -4000, y: 0))   // off screen, but still laid out and drawn
        win.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(shot.name + ".png")) }
        win.orderOut(nil)
    }
}

/// A menu bar with the popover hanging from the icon, on a soft backdrop. Used only for screenshots.
struct PopoverShot: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color(red: 0.62, green: 0.71, blue: 0.78), Color(red: 0.29, green: 0.37, blue: 0.49)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text("Finder").bold(); Text("File"); Text("Edit"); Text("View")
                    Spacer()
                    Image(nsImage: StatusIcon.image(.active)).renderingMode(.template).padding(.horizontal, 6).padding(.vertical, 2).background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    Text("Tue 20 Oct  9:41")
                }.font(.system(size: 13)).foregroundStyle(.primary).padding(.horizontal, 14).frame(height: 28).background(.regularMaterial)
                PopoverView(openManager: { _ in })
                    .clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.15)))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12).padding(.top, 8).padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Spacer()
            }
        }
    }
}

/// Made-up data that looks like a typical day.
@MainActor enum Demo {
    static func install() {
        let m = AppModel.shared
        m.demo = true
        m.setupState = SetupState(items: [])
        m.status = "All good"
        m.loadedOnce = true; m.updatedAt = .now
        let c = Calendar(identifier: .gregorian)
        func d(_ mo: Int, _ y: Int = 2026) -> Date { c.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: y, month: mo, day: 1))! }
        let launch = Page(id: "launch", title: "Launch plan", blocks: [
            Block(kind: .text, text: "Ship the first public build of Antsly and collect feedback from the first 50 users."),
            Block(kind: .callout, text: "Goal: a stable 0.1 release with cloud sync by the end of the month."),
            Block(kind: .todo, text: "Write the README with screenshots", checked: true),
            Block(kind: .todo, text: "Publish the GitHub Pages site", checked: true),
            Block(kind: .todo, text: "Record a 30 second demo"),
            Block(kind: .todo, text: "Tag v0.1.0 and attach the signed DMG"),
            Block(kind: .heading, text: "Notes"), Block(kind: .bullet, text: "Invite the first testers over Tailscale"), Block(kind: .bullet, text: "Track feedback as GitHub issues")])
        let meet = Page(id: "meet", title: "Meeting notes", blocks: [Block(kind: .text, text: "Weekly sync.")])
        let wiki = Page(id: "wiki", title: "Product wiki", blocks: [Block(kind: .text, text: "How Antsly works.")])
        var roadmap = Database.tasks(title: "Roadmap")
        roadmap.rows = [("Block editor", "In progress", "Mo", "Nov 12"), ("Database views", "Planned", "Mo", "Nov 20"), ("Cloud sync", "In progress", "Mo", "Nov 24"), ("App icon and README", "Done", "Mo", "Nov 8"), ("GitHub Pages site", "Planned", "Mo", "Nov 28")]
            .map { .init(cells: ["name": $0.0, "status": $0.1, "owner": $0.2, "due": $0.3]) }
        let ph = [Plan.Phase(id: "a", name: "Foundation", color: "#2563EB"), .init(id: "b", name: "Front-end upgrade", color: "#D97706"), .init(id: "c", name: "Backend integrity", color: "#059669"), .init(id: "d", name: "Performance", color: "#DC2626")]
        let ppl = ["Jinhua", "Dan", "Albert", "Josh", "Rouh", "Sri", "Mo"].map { Plan.Person(id: $0, name: $0) }
        func t(_ ph: String, _ n: String, _ a: [String], _ s: Int, _ e: Int, _ st: Plan.Status = .notStarted, _ p: Double = 0, crit: Bool = false) -> Plan.Task {
            .init(phaseID: ph, name: n, start: d(s > 12 ? s - 12 : s, s > 12 ? 2027 : 2026), end: d(e > 12 ? e - 12 : e, e > 12 ? 2027 : 2026), assignments: a.map { .init(personID: $0) }, status: st, progress: p, critical: crit)
        }
        let plan = Plan(title: "Modernisation plan", phases: ph, people: ppl, tasks: [
            t("a", "Automated test cycles", ["Jinhua", "Dan", "Albert"], 4, 10, .inProgress, 0.7), t("a", "E2E scenario reconstruction", ["Dan"], 4, 10, .inProgress, 0.4), t("a", "Test data management", ["Rouh", "Sri"], 7, 10, .inProgress, 0.35),
            t("b", "Angular/Atom removal", ["Josh", "Dan"], 13, 16, crit: true), t("b", "Angular 9 to 12 upgrade", ["Josh", "Dan"], 16, 19), t("b", "Dependencies and tooling", ["Josh"], 4, 22, .inProgress, 0.2),
            t("c", "AdonisJS to ExpressJS", ["Rouh"], 13, 19), t("c", "Backend dependency updates", ["Rouh", "Sri", "Mo"], 13, 19), t("c", "Type checking and safety", ["Rouh"], 13, 19),
            t("d", "Load test environment", ["Rouh", "Sri", "Mo", "Dan"], 19, 22, crit: true), t("d", "Increase test coverage", ["Sri", "Dan", "Rouh", "Mo"], 19, 22), t("d", "Laravel LTS update", ["Sri", "Dan", "Mo"], 19, 22, .atRisk)])
        WorkspaceModel.shared.loadDemo(pages: [launch, meet, wiki], databases: [roadmap], plans: [plan])
    }
}
