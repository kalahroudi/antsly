// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AntslyKit

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")); if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let v = UInt32(h, radix: 16) ?? 0x6B7280
        self.init(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

extension Plan.Status {
    var label: String { switch self { case .notStarted: "Not started"; case .inProgress: "In progress"; case .completed: "Completed"; case .atRisk: "At risk"; case .archived: "Archived" } }
    var color: Color { switch self { case .notStarted: Color(hex: "#94a3b8"); case .inProgress: Color(hex: "#3b82f6"); case .completed: Color(hex: "#10b981"); case .atRisk: Color(hex: "#f59e0b"); case .archived: Color(hex: "#cbd5e1") } }
}

/// A project plan with a timeline, a task list, resource workload with burnup, and a status report.
struct PlanView: View {
    let id: String
    private var nav: Nav { Nav.shared }
    @State private var editing: String?
    @State private var showPeople = false
    let ws = WorkspaceModel.shared
    enum Tab: Hashable { case timeline, list, workload, report }

    var plan: Plan? { ws.plans.first { $0.id == id } }

    var body: some View {
        if let plan {
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    PaneHeader(title: "", subtitle: nil, trailing: { controls }, tabs: { EmptyView() })
                        .overlay(alignment: .leading) {
                            TextField("Plan name", text: Binding(get: { plan.title }, set: { v in ws.editPlan(id) { $0.title = v } })).textFieldStyle(.plain)
                                .font(.system(size: 19, weight: .semibold)).padding(.leading, 22).padding(.top, 26).padding(.trailing, 560)
                        }
                    switch nav.planTab {
                    case .timeline: Timeline(plan: plan, edit: { editing = $0 })
                    case .list: TaskList(plan: plan, edit: { editing = $0 })
                    case .workload: Workload(plan: plan)
                    case .report: ReportView(plan: plan)
                    }
                }
                if let tid = editing, plan.tasks.contains(where: { $0.id == tid }) {
                    Color.black.opacity(0.18).onTapGesture { editing = nil }
                    TaskEditor(planID: id, taskID: tid) { editing = nil }.transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.18), value: editing)
            .sheet(isPresented: $showPeople) { PeopleSheet(planID: id) }
            .onExitCommand { editing = nil }
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
            Segmented(options: [(Tab.timeline, "Timeline"), (Tab.list, "List"), (Tab.workload, "Workload"), (Tab.report, "Report")], selection: Binding(get: { nav.planTab }, set: { nav.planTab = $0 }))
            Button { showPeople = true } label: { Label("People", systemImage: "person.2") }.buttonStyle(Pill())
            Button { addPhase() } label: { Label("Phase", systemImage: "plus") }.buttonStyle(Pill())
            Button { addTask() } label: { Label("Task", systemImage: "plus") }.buttonStyle(Pill(kind: .primary))
        }
    }

    private func addPhase() {
        let colors = ["#2563EB", "#D97706", "#059669", "#DC2626", "#7C3AED", "#6B7280"]
        ws.editPlan(id) { p in p.phases.append(.init(name: "Phase \(p.phases.count + 1)", color: colors[p.phases.count % colors.count])) }
    }
    private func addTask() {
        guard let plan, let ph = plan.phases.last else { addPhase(); return }
        let start = plan.tasks.map(\.start).min() ?? Date()
        let t = Plan.Task(phaseID: ph.id, name: "New task", start: start, end: start.addingTimeInterval(86400 * 28))
        ws.editPlan(id) { $0.tasks.append(t) }
        editing = t.id
    }
}

/// The Gantt chart. The scale (weeks, months or quarters) follows the length of the plan so it always fits the window.
struct Timeline: View {
    let plan: Plan
    var edit: (String) -> Void
    let ws = WorkspaceModel.shared
    private let nameWidth: CGFloat = 250, rowH: CGFloat = 26

    private var range: (Date, Date) {
        let s = plan.tasks.map(\.start).min() ?? Date(), e = plan.tasks.map(\.end).max() ?? Date().addingTimeInterval(86400 * 90)
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let a = c.dateInterval(of: .month, for: s)!.start, b = c.dateInterval(of: .month, for: e.addingTimeInterval(-1))!.end
        return (a, b)
    }
    private var ticks: [(Date, String)] {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let (a, b) = range
        let months = c.dateComponents([.month], from: a, to: b).month ?? 1
        let step = months <= 8 ? 1 : (months <= 30 ? 3 : 12)
        var out: [(Date, String)] = []; var d = a
        let f = DateFormatter(); f.timeZone = c.timeZone
        while d < b {
            f.dateFormat = step == 1 ? "MMM" : (step == 3 ? "QQQ ''yy" : "yyyy")
            out.append((d, f.string(from: d))); d = c.date(byAdding: .month, value: step, to: d)!
        }
        return out
    }

    var body: some View {
        let (a, b) = range, total = b.timeIntervalSince(a)
        VStack(spacing: 0) {
            GeometryReader { geo in
                let w = max(100, geo.size.width - nameWidth - 24)
                let x: (Date) -> CGFloat = { CGFloat($0.timeIntervalSince(a) / total) * w }
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Task").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 12).frame(width: nameWidth, alignment: .leading)
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(ticks.enumerated()), id: \.offset) { _, t in Text(t.1).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).offset(x: x(t.0) + 4) }
                        }.frame(width: w, height: 22, alignment: .topLeading)
                    }.padding(.vertical, 4)
                    Divider()
                    StyledScroll {
                        VStack(spacing: 0) {
                            ForEach(plan.phases) { ph in
                                row(left: AnyView(phaseLabel(ph)), w: w, x: x, a: a, bar: nil, phase: ph)
                                ForEach(plan.tasks.filter { $0.phaseID == ph.id }) { t in
                                    row(left: AnyView(Text(t.name).font(.system(size: 12.5)).lineLimit(1).padding(.leading, 14)), w: w, x: x, a: a, bar: t, phase: ph)
                                }
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            // Today marker
                            if Date() >= a && Date() <= b { Rectangle().fill(Theme.accent.opacity(0.7)).frame(width: 1.5).offset(x: nameWidth + x(Date())) }
                        }
                    }
                }.padding(.horizontal, 10)
            }
            legend
        }
    }

    private func row(left: AnyView, w: CGFloat, x: @escaping (Date) -> CGFloat, a: Date, bar: Plan.Task?, phase: Plan.Phase) -> some View {
        HStack(spacing: 0) {
            left.padding(.leading, 12).frame(width: nameWidth, alignment: .leading)
            ZStack(alignment: .leading) {
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, t in Rectangle().fill(Theme.hairline).frame(width: 1).offset(x: x(t.0)) }
                if let t = bar {
                    let bx = x(t.start), bw = max(8, x(t.end) - bx)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5).fill(t.status.color)
                        if t.progress > 0 && t.status != .completed { RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.28)).frame(width: bw * t.progress) }
                        Text(owners(t)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 5).lineLimit(1)
                    }
                    .frame(width: bw, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.accent, lineWidth: t.critical ? 2 : 0).padding(-1))
                    .offset(x: bx).contentShape(Rectangle()).onTapGesture { edit(t.id) }
                    .help("\(t.name): \(t.status.label)")
                }
            }.frame(width: w, height: rowH, alignment: .leading)
        }
        .frame(height: rowH)
        .background(bar == nil ? Theme.fill : .clear)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        .contentShape(Rectangle()).onTapGesture { if let t = bar { edit(t.id) } }
    }

    /// A phase's name is edited in place. The dot opens colour and delete.
    private func phaseLabel(_ ph: Plan.Phase) -> some View { PhaseLabel(planID: plan.id, phase: ph, taskCount: plan.tasks.filter { $0.phaseID == ph.id }.count) }

    private func owners(_ t: Plan.Task) -> String {
        let names = t.assignments.compactMap { a in plan.people.first { $0.id == a.personID }?.name }
        return names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " +\(names.count - 2)" : "")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([Plan.Status.inProgress, .completed, .atRisk, .notStarted], id: \.self) { s in HStack(spacing: 5) { RoundedRectangle(cornerRadius: 3).fill(s.color).frame(width: 10, height: 10); Text(s.label) } }
            HStack(spacing: 5) { RoundedRectangle(cornerRadius: 3).stroke(Theme.accent, lineWidth: 2).frame(width: 10, height: 10); Text("Critical") }
            HStack(spacing: 5) { Rectangle().fill(Theme.accent).frame(width: 2, height: 10); Text("Today") }
            Spacer()
            Text("Click a bar to edit").foregroundStyle(.secondary)
        }.font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 8)
    }
}

struct TaskList: View {
    let plan: Plan
    var edit: (String) -> Void
    var body: some View {
        StyledScroll {
            VStack(spacing: 0) {
                ForEach(plan.tasks) { t in
                    Button { edit(t.id) } label: {
                        HStack(spacing: 10) {
                            Circle().fill(t.status.color).frame(width: 9, height: 9)
                            Text(t.name).font(.system(size: 13)).lineLimit(1)
                            if t.critical { Badge(text: "critical", kind: .danger) }
                            Spacer()
                            Text(plan.people.filter { p in t.assignments.contains { $0.personID == p.id } }.map(\.name).joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            Text("\(t.start.formatted(.dateTime.day().month(.abbreviated))) to \(t.end.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated).year(.twoDigits)))").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
                            Text("\(Int(t.progress * 100))%").font(.system(size: 12)).frame(width: 40, alignment: .trailing)
                        }.padding(.horizontal, 22).padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider().opacity(0.6)
                }
            }
        }
    }
}

/// Right-side sheet for one task. Closes with Esc or a click outside; every field saves as you type.
struct TaskEditor: View {
    let planID: String, taskID: String
    var close: () -> Void
    let ws = WorkspaceModel.shared
    @State private var confirmDelete = false

    private var plan: Plan? { ws.plans.first { $0.id == planID } }
    private var task: Plan.Task? { plan?.tasks.first { $0.id == taskID } }
    private func set(_ change: @escaping (inout Plan.Task) -> Void) { ws.editPlan(planID) { p in if let i = p.tasks.firstIndex(where: { $0.id == taskID }) { change(&p.tasks[i]) } } }

    var body: some View {
        if let t = task, let plan {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Task").font(.system(size: 15, weight: .semibold)); Spacer(); Button { close() } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Close") }
                TextField("Task name", text: Binding(get: { t.name }, set: { v in set { $0.name = v } })).textFieldStyle(.roundedBorder)
                Picker("Phase", selection: Binding(get: { t.phaseID }, set: { v in set { $0.phaseID = v } })) { ForEach(plan.phases) { Text($0.name).tag($0.id) } }
                DatePicker("Starts", selection: Binding(get: { t.start }, set: { v in set { $0.start = v; if $0.end <= v { $0.end = v.addingTimeInterval(86400 * 7) } } }), displayedComponents: .date)
                DatePicker("Ends", selection: Binding(get: { t.end.addingTimeInterval(-86400) }, set: { v in set { $0.end = max(v.addingTimeInterval(86400), $0.start.addingTimeInterval(86400)) } }), displayedComponents: .date)
                Picker("Status", selection: Binding(get: { t.status }, set: { v in set { $0.status = v; if v == .completed { $0.progress = 1 } } })) { ForEach(Plan.Status.allCases, id: \.self) { Text($0.label).tag($0) } }
                HStack { Text("Progress"); Slider(value: Binding(get: { t.progress }, set: { v in set { $0.progress = v; if v >= 1 { $0.status = .completed } else if v > 0 && $0.status == .notStarted { $0.status = .inProgress } } }), in: 0...1); Text("\(Int(t.progress * 100))%").frame(width: 36) }
                Toggle("On the critical path", isOn: Binding(get: { t.critical }, set: { v in set { $0.critical = v } })).toggleStyle(.switch).tint(Theme.accent)
                if plan.unit == .storyPoints {
                    HStack { Text("Story points"); TextField("0", value: Binding(get: { t.points ?? 0 }, set: { v in set { $0.points = v } }), format: .number).textFieldStyle(.roundedBorder).frame(width: 70) }
                }
                SectionLabel("Who works on it, days per week")
                ForEach(plan.people) { p in
                    let a = t.assignments.first { $0.personID == p.id }
                    HStack {
                        Toggle(p.name, isOn: Binding(get: { a != nil }, set: { on in set { if on { $0.assignments.append(.init(personID: p.id)) } else { $0.assignments.removeAll { $0.personID == p.id } } } })).toggleStyle(.checkbox)
                        Spacer()
                        if let a { Stepper(String(format: "%.1f", a.daysPerWeek), value: Binding(get: { a.daysPerWeek }, set: { v in set { if let i = $0.assignments.firstIndex(where: { $0.personID == p.id }) { $0.assignments[i].daysPerWeek = v } } }), in: 0.5...5, step: 0.5).frame(width: 110) }
                    }
                }
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete task", systemImage: "trash") }.buttonStyle(Pill(kind: .danger))
                    .confirmationDialog("Delete \"\(t.name)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) { ws.editPlan(planID) { $0.tasks.removeAll { $0.id == taskID } }; close() }
                        Button("Cancel", role: .cancel) {}
                    }
            }
            .padding(18).frame(width: 360).frame(maxHeight: .infinity, alignment: .top).background(Theme.pane)
            .overlay(alignment: .leading) { Divider() }
        }
    }
}

struct PeopleSheet: View {
    let planID: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var removing: Plan.Person?
    let ws = WorkspaceModel.shared
    private var plan: Plan? { ws.plans.first { $0.id == planID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("People").font(.system(size: 16, weight: .semibold))
            Text("Capacity is the days per week a person can work on this plan. Leave and holidays reduce it.").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(plan?.people ?? []) { p in
                HStack {
                    Text(p.name).frame(maxWidth: .infinity, alignment: .leading)
                    Stepper("\(String(format: "%.1f", p.daysPerWeek)) days/week", value: Binding(get: { p.daysPerWeek }, set: { v in ws.editPlan(planID) { pl in if let i = pl.people.firstIndex(where: { $0.id == p.id }) { pl.people[i].daysPerWeek = v } } }), in: 0.5...7, step: 0.5)
                    Button(role: .destructive) { removing = p } label: { Image(systemName: "trash").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Remove \(p.name)")
                }
            }
            HStack { TextField("Add a person", text: $name).textFieldStyle(.roundedBorder).onSubmit(add); Button("Add", action: add).buttonStyle(Pill(kind: .primary)) }
            HStack {
                Text("Count progress in").font(.system(size: 12.5))
                Segmented(options: [(Plan.Unit.personDays, "Person-days"), (.storyPoints, "Story points"), (.tasks, "Tasks")], selection: Binding(get: { plan?.unit ?? .personDays }, set: { v in ws.editPlan(planID) { $0.unit = v } }))
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(Pill(kind: .primary)) }
        }.padding(20).frame(width: 520)
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let p = removing { ws.editPlan(planID) { pl in pl.people.removeAll { $0.id == p.id }; for i in pl.tasks.indices { pl.tasks[i].assignments.removeAll { $0.personID == p.id } } } }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("They are taken off every task they were assigned to.") }
    }
    private func add() {
        let n = name.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        ws.editPlan(planID) { $0.people.append(.init(name: n)) }; name = ""
    }
}

struct PhaseLabel: View {
    let planID: String
    let phase: Plan.Phase
    let taskCount: Int
    @State private var open = false
    @State private var confirmDelete = false
    let ws = WorkspaceModel.shared
    private let palette = ["#2563EB", "#D97706", "#059669", "#DC2626", "#7C3AED", "#6B7280"]

    private func edit(_ change: @escaping (inout Plan.Phase) -> Void) {
        ws.editPlan(planID) { p in if let i = p.phases.firstIndex(where: { $0.id == phase.id }) { change(&p.phases[i]) } }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { open = true } label: { Circle().fill(Color(hex: phase.color)).frame(width: 10, height: 10).frame(width: 20, height: 24).contentShape(Rectangle()) }
                .buttonStyle(.plain).help("Phase colour and delete").accessibilityLabel("Phase options")
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Colour").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(palette, id: \.self) { c in
                                Button { edit { $0.color = c } } label: {
                                    Circle().fill(Color(hex: c)).frame(width: 20, height: 20)
                                        .overlay(Circle().stroke(Color.primary, lineWidth: c == phase.color ? 2 : 0).padding(-3))
                                }.buttonStyle(.plain).accessibilityLabel("Colour \(c)")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            open = false; confirmDelete = true
                        } label: { Text("Delete phase" + (taskCount > 0 ? " and its \(taskCount) task\(taskCount == 1 ? "" : "s")" : "")).foregroundStyle(Theme.danger) }
                            .buttonStyle(.plain)
                    }.padding(14)
                }
            TextField("Phase name", text: Binding(get: { phase.name }, set: { v in edit { $0.name = v } }))
                .textFieldStyle(.plain).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
        }
        .confirmationDialog("Delete \"\(phase.name)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete" + (taskCount > 0 ? " phase and \(taskCount) task\(taskCount == 1 ? "" : "s")" : ""), role: .destructive) {
                ws.editPlan(planID) { p in p.phases.removeAll { $0.id == phase.id }; p.tasks.removeAll { $0.phaseID == phase.id } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
