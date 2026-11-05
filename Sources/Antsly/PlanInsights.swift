// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import Charts
import AppKit
import AntslyKit

private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 2; return c }

/// Resource heatmap and burnup, by day, week, month or year.
struct Workload: View {
    let plan: Plan
    @State private var view: V = .heat
    @State private var gran: G = .month
    @State private var offset = 0
    enum V: Hashable { case heat, burn }
    enum G: Hashable { case day, week, month, year }

    struct Period: Identifiable { var a: Date, b: Date, label: String; var id: Date { a } }

    private var periods: [Period] {
        let c = utc, now = Date()
        var out: [Period] = []
        let f = DateFormatter(); f.timeZone = c.timeZone
        switch gran {
        case .day:
            let s = c.date(byAdding: .day, value: -3 + offset * 14, to: c.startOfDay(for: now))!
            f.dateFormat = "EEEEE d"
            for i in 0..<14 { let a = c.date(byAdding: .day, value: i, to: s)!; out.append(Period(a: a, b: c.date(byAdding: .day, value: 1, to: a)!, label: f.string(from: a))) }
        case .week:
            let wk = c.dateInterval(of: .weekOfYear, for: now)!.start
            let s = c.date(byAdding: .weekOfYear, value: -4 + offset * 13, to: wk)!
            for i in 0..<13 { let a = c.date(byAdding: .weekOfYear, value: i, to: s)!; out.append(Period(a: a, b: c.date(byAdding: .weekOfYear, value: 1, to: a)!, label: "W\(c.component(.weekOfYear, from: a))")) }
        case .month:
            let m = c.dateInterval(of: .month, for: now)!.start
            let s = c.date(byAdding: .month, value: -3 + offset * 12, to: m)!
            f.dateFormat = "MMM"
            for i in 0..<12 { let a = c.date(byAdding: .month, value: i, to: s)!; out.append(Period(a: a, b: c.date(byAdding: .month, value: 1, to: a)!, label: f.string(from: a))) }
        case .year:
            let y = c.dateInterval(of: .year, for: now)!.start
            let s = c.date(byAdding: .year, value: offset * 3, to: y)!
            f.dateFormat = "yyyy"
            for i in 0..<3 { let a = c.date(byAdding: .year, value: i, to: s)!; out.append(Period(a: a, b: c.date(byAdding: .year, value: 1, to: a)!, label: f.string(from: a))) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Segmented(options: [(V.heat, "Heatmap"), (.burn, "Burnup")], selection: $view)
                Segmented(options: [(G.day, "Day"), (.week, "Week"), (.month, "Month"), (.year, "Year")], selection: Binding(get: { gran }, set: { gran = $0; offset = 0 }))
                HStack(spacing: 2) {
                    Button { offset -= 1 } label: { Image(systemName: "chevron.left").frame(width: 24, height: 22).contentShape(Rectangle()) }.buttonStyle(Pill()).accessibilityLabel("Earlier")
                    Button("Today") { offset = 0 }.buttonStyle(Pill())
                    Button { offset += 1 } label: { Image(systemName: "chevron.right").frame(width: 24, height: 22).contentShape(Rectangle()) }.buttonStyle(Pill()).accessibilityLabel("Later")
                }
                Spacer()
                if let f = periods.first, let l = periods.last { Text("\(f.a.formatted(.dateTime.day().month(.abbreviated).year())) to \(l.b.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated).year()))").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            if view == .heat { heat } else { Burnup(plan: plan, periods: periods.map { ($0.a, $0.b) }) }
            Spacer(minLength: 0)
        }.padding(.horizontal, 22).padding(.vertical, 14)
    }

    private var heat: some View {
        let ps = periods
        return VStack(alignment: .leading, spacing: 8) {
            if plan.people.isEmpty { Text("Add people to see their workload.").foregroundStyle(.secondary) }
            HStack(spacing: 3) {
                Text("").frame(width: 100)
                ForEach(ps) { p in Text(p.label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }
            ForEach(plan.people) { person in
                HStack(spacing: 3) {
                    Text(person.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).frame(width: 100, alignment: .leading)
                    ForEach(ps) { p in
                        let weekend = gran == .day && [1, 7].contains(utc.component(.weekday, from: p.a))
                        let u = weekend ? 0 : PlanMath.utilization(person: person, in: plan, from: p.a, to: p.b)
                        Text(weekend || u == 0 ? "" : "\(Int((u * 100).rounded()))")
                            .font(.system(size: 11.5, weight: .medium)).frame(maxWidth: .infinity).frame(height: 28)
                            .foregroundStyle(u > 1 ? Theme.onAccent : Color.primary)
                            .background(u > 1 ? Theme.accent : (u > 0 ? Color.blue.opacity(0.14 + min(u, 1) * 0.6) : Theme.fill), in: RoundedRectangle(cornerRadius: 6))
                            .opacity(weekend ? 0.45 : 1)
                            .help("\(person.name): \(Int((u * 100).rounded()))% booked")
                    }
                }
            }
            let hot = plan.people.filter { pe in ps.contains { PlanMath.utilization(person: pe, in: plan, from: $0.a, to: $0.b) > 1 } }
            HStack(spacing: 14) {
                legend(Color.blue.opacity(0.3), "Under capacity"); legend(Color.blue.opacity(0.75), "Fully booked"); legend(Theme.accent, "Over 100%")
                Text("Numbers are % of each person's capacity").foregroundStyle(.secondary)
            }.font(.system(size: 11.5)).padding(.top, 4)
            if !hot.isEmpty {
                Text("Overloaded in this window: \(hot.map(\.name).joined(separator: ", ")). Move a task or add a person.").font(.system(size: 12.5))
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private func legend(_ c: Color, _ t: String) -> some View { HStack(spacing: 5) { RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 10, height: 10); Text(t) } }
}

struct Burnup: View {
    let plan: Plan
    let periods: [(Date, Date)]
    private struct Pt: Identifiable { var id = UUID(); var date: Date; var series: String; var value: Double }

    var body: some View {
        let dates = [periods.first!.0] + periods.map { $0.1 }
        let pts = PlanMath.burnup(plan, at: dates, now: Date())
        let unit = plan.unit == .personDays ? "person-days" : plan.unit == .storyPoints ? "story points" : "tasks"
        let nowPt = PlanMath.burnup(plan, at: [Date()], now: Date()).first
        let data: [Pt] = pts.flatMap { p -> [Pt] in
            var a = [Pt(date: p.date, series: "Scope", value: p.scope), Pt(date: p.date, series: "Planned", value: p.planned)]
            if let c = p.completed { a.append(Pt(date: p.date, series: "Completed", value: c)) }
            return a
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                kpi("\(fmt(nowPt?.scope ?? 0))", "scope, \(unit)")
                kpi("\(fmt(nowPt?.completed ?? 0))", "completed")
                kpi("\(fmt(nowPt?.planned ?? 0))", "planned by today")
                let pc = (nowPt?.planned ?? 0) > 0 ? Int(((nowPt?.completed ?? 0) / (nowPt?.planned ?? 1) * 100).rounded()) : 0
                kpi("\(pc)%", "of plan")
            }
            Chart(data) { d in
                LineMark(x: .value("Date", d.date), y: .value(unit, d.value), series: .value("Series", d.series))
                    .foregroundStyle(by: .value("Series", d.series))
                    .lineStyle(StrokeStyle(lineWidth: d.series == "Completed" ? 3 : 2, dash: d.series == "Scope" ? [5, 3] : []))
                    .interpolationMethod(.linear)
                if Date() >= periods.first!.0 && Date() <= periods.last!.1 { RuleMark(x: .value("Today", Date())).foregroundStyle(Theme.accent.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3])) }
            }
            .chartForegroundStyleScale(["Scope": Color.secondary, "Planned": Color.blue, "Completed": Theme.accent])
            .chartYAxisLabel(unit)
            .frame(minHeight: 240)
            Text(plan.snapshots.isEmpty ? "Completed work is recorded from your task progress. History builds up as you update the plan." : "Completed work comes from \(plan.snapshots.count) recorded snapshots.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
    private func fmt(_ v: Double) -> String { v >= 100 ? String(Int(v.rounded())) : String(format: "%.1f", v) }
    private func kpi(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 1) { Text(v).font(.system(size: 21, weight: .semibold)); Text(l).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, alignment: .leading).card(padding: 10)
    }
}

/// A status report for the plan: copy as Markdown, save as a page, or export a PDF.
struct ReportView: View {
    let plan: Plan
    let ws = WorkspaceModel.shared

    var body: some View {
        let r = PlanMath.report(plan, now: Date())
        VStack(spacing: 0) {
            HStack {
                Text("Generated \(Date().formatted(date: .abbreviated, time: .omitted))").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Copy Markdown") { Clipboard.copy(PlanMath.markdown(plan, report: r, now: Date())); AppModel.shared.show("Report copied.") }.buttonStyle(Pill())
                Button("Export PDF") { exportPDF(r) }.buttonStyle(Pill())
                Button("Save as page") { saveAsPage(r) }.buttonStyle(Pill(kind: .primary))
            }.padding(.horizontal, 22).padding(.vertical, 10)
            Divider()
            StyledScroll { content(r).padding(22).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private func content(_ r: PlanMath.Report) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                kpi("\(r.total)", "tasks in \(plan.phases.count) phases"); kpi("\(r.completed)", "completed, \(r.inProgress) in progress")
                kpi("\(r.atRisk)", "at risk", Theme.warn); kpi("\(r.critical)", "on the critical path", Theme.accent)
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Progress by phase")
                    ForEach(Array(r.phaseProgress.enumerated()), id: \.offset) { i, p in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(p.name).font(.system(size: 12.5)); Spacer(); Text("\(p.percent)%").font(.system(size: 12.5, weight: .semibold)) }
                            ProgressView(value: Double(p.percent), total: 100).tint(i < plan.phases.count ? Color(hex: plan.phases[i].color) : Theme.accent)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Needs attention")
                    let risk = plan.tasks.filter { $0.status == .atRisk }.map(\.name)
                    note("At risk", risk.isEmpty ? "Nothing is flagged at risk." : risk.joined(separator: ", "))
                    note("Critical path", r.criticalPath.isEmpty ? "No critical tasks are marked." : r.criticalPath.joined(separator: " → "))
                    note("Overloaded in the next quarter", r.overloaded.isEmpty ? "Nobody is over capacity." : r.overloaded.joined(separator: ", "))
                    note("Starting soon", r.upcoming.isEmpty ? "Nothing starts in the next quarter." : r.upcoming.joined(separator: ", "))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func note(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(t).font(.system(size: 12, weight: .semibold)); Text(d).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
    }
    private func kpi(_ v: String, _ l: String, _ c: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) { Text(v).font(.system(size: 22, weight: .semibold)).foregroundStyle(c); Text(l).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, alignment: .leading).card(padding: 10)
    }

    private func saveAsPage(_ r: PlanMath.Report) {
        var page = PageMarkdown.parse(PlanMath.markdown(plan, report: r, now: Date()), fallbackID: UUID().uuidString, updated: Date().timeIntervalSince1970)
        page.id = UUID().uuidString
        ws.mergeRemote(page)       // adds the page and schedules the save
        ws.selected = .page(page.id)
        AppModel.shared.show("Saved the report as a page.")
    }

    @MainActor private func exportPDF(_ r: PlanMath.Report) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "\(plan.title) report.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let page = VStack(alignment: .leading, spacing: 14) {
            Text("\(plan.title): status report").font(.system(size: 22, weight: .bold))
            content(r)
        }.padding(36).frame(width: 760, alignment: .leading).background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: page)
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage(); ctx.closePDF()
        }
        AppModel.shared.show("Exported the PDF.")
    }
}
