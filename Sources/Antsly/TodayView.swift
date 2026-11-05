// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AntslyKit

/// The AI briefing, kept between visits so it is not rewritten every time the view opens.
@MainActor @Observable
final class TodayModel {
    static let shared = TodayModel()
    var briefing: String?
    var briefingAt: Date?
    var busy = false

    func refresh(facts: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { briefing = try await AIBriefing.run(facts: facts); briefingAt = .now }
        catch { AppLog.error(error, context: "briefing"); AppModel.shared.show(UserError.message(for: error, action: "Writing the summary"), error: true) }
    }
}

/// A bird's-eye view of the day: what is due, what is late, what has no time yet, and a short summary written by the user's own Claude Code.
struct TodayView: View {
    let ws = WorkspaceModel.shared
    let model = TodayModel.shared
    @State private var days = 1

    private var summary: TodaySummary { TodayPlan.build(pages: ws.pages, databases: ws.databases, plans: ws.plans, reminders: ws.reminders, windowDays: days) }

    var body: some View {
        let s = summary
        VStack(spacing: 0) {
            PaneHeader(title: "", subtitle: nil, trailing: { controls }, tabs: { EmptyView() })
                .overlay(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Today").font(.system(size: 19, weight: .semibold))
                        Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.leading, 22).padding(.top, 26)
                }
            StyledScroll {
                VStack(alignment: .leading, spacing: 20) {
                    briefing(s)
                    StatStrip(stats: [("\(s.dueToday)", "due today"), ("\(s.overdue.count)", "overdue"), ("\(s.suggestions.count)", "to-dos without a time"), ("\(s.remindersToday)", "reminders today")])
                    HStack(alignment: .top, spacing: 20) {
                        schedule(s).frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 20) { attention(s); needsTime(s) }.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }.padding(22)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Segmented(options: [(1, "Today"), (7, "This week")], selection: $days)
            Button { planDay() } label: { Label("Plan my day", systemImage: "sparkles") }.buttonStyle(Pill(kind: .primary)).disabled(model.busy)
                .help("Gives every to-do without a time a reminder, then writes the summary")
        }
    }

    // MARK: Summary

    private func briefing(_ s: TodaySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text("Your day, summarised").font(.system(size: 12.5, weight: .semibold))
                if let at = model.briefingAt { Text("by Claude Code, \(at.formatted(date: .omitted, time: .shortened))").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await model.refresh(facts: s.text()) } }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).disabled(model.busy || !AIOrganizer.available)
                    .help(AIOrganizer.available ? "Ask your Claude Code to write the summary. Your tasks are sent to it." : "Needs Claude Code installed")
            }
            Text(model.briefing ?? plainSummary(s)).font(.system(size: 14.5)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Schedule the \(s.suggestions.count) without a time") { accept(s.suggestions) }.buttonStyle(Pill()).disabled(s.suggestions.isEmpty)
                Button("Add reminders to deadlines") { remindDeadlines(s) }.buttonStyle(Pill()).disabled(deadlinesWithoutReminder(s).isEmpty)
                Button("Copy as stand-up note") { Clipboard.copy(s.text()); AppModel.shared.show("Copied.") }.buttonStyle(Pill())
            }
            if model.briefing == nil { Text("Refresh to have Claude Code write this. Your tasks are sent to it only then.").font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    private func plainSummary(_ s: TodaySummary) -> String {
        if s.schedule.isEmpty && s.overdue.isEmpty && s.suggestions.isEmpty { return "Nothing is due. Select text on a page and choose Remind me to add something here." }
        var parts: [String] = []
        if s.dueToday > 0 { parts.append("\(s.dueToday) due today") }
        if !s.overdue.isEmpty { parts.append("\(s.overdue.count) overdue") }
        if s.remindersToday > 0 { parts.append("\(s.remindersToday) reminder\(s.remindersToday == 1 ? "" : "s") today") }
        if !s.suggestions.isEmpty { parts.append("\(s.suggestions.count) to-do\(s.suggestions.count == 1 ? "" : "s") without a time") }
        return parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst() + "."
    }

    // MARK: Lists

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(spacing: 0, content: content).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        }
    }

    private func schedule(_ s: TodaySummary) -> some View {
        section(days > 1 ? "COMING UP" : "TODAY'S SCHEDULE") {
            if s.schedule.isEmpty { Text("Nothing scheduled.").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(Array(s.schedule.enumerated()), id: \.element.id) { i, item in
                if days > 1, i == 0 || !Calendar.current.isDate(item.when, inSameDayAs: s.schedule[i - 1].when) {
                    Text(item.when.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2).frame(maxWidth: .infinity, alignment: .leading)
                }
                row(item)
                if i < s.schedule.count - 1 { Divider().opacity(0.6) }
            }
        }
    }

    private func row(_ item: TodayItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.timed ? item.when.formatted(date: .omitted, time: .shortened) : "All day").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text(item.detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if item.kind == .reminder, let id = item.id.split(separator: "-", maxSplits: 1).last.map(String.init) {
                Button("Done") { ws.finishReminder(id) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
            } else {
                ReminderButton(title: item.title, target: item.target, compact: true)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle()).onTapGesture { ws.open(item.target) }
    }

    @ViewBuilder private func attention(_ s: TodaySummary) -> some View {
        if !s.overdue.isEmpty || !s.attentionOrder.isEmpty {
            section("NEEDS ATTENTION") {
                ForEach(Array(s.overdue.prefix(4).enumerated()), id: \.element.id) { i, item in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) { Text(item.title).font(.system(size: 13, weight: .semibold)); Text("\(item.overdueDays) day\(item.overdueDays == 1 ? "" : "s") overdue").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.danger) }
                        Text(item.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).onTapGesture { ws.open(item.target) }
                    if i < min(s.overdue.count, 4) - 1 || s.overdue.count > 4 || !s.attentionOrder.isEmpty { Divider().opacity(0.6) }
                }
                if s.overdue.count > 4 {
                    Text("and \(s.overdue.count - 4) more overdue").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    if !s.attentionOrder.isEmpty { Divider().opacity(0.6) }
                }
                ForEach(Array(s.attentionOrder.enumerated()), id: \.offset) { i, h in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(h).font(.system(size: 13, weight: .semibold))
                        Text(s.attention[h] ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    if i < s.attentionOrder.count - 1 { Divider().opacity(0.6) }
                }
            }
        }
    }

    @ViewBuilder private func needsTime(_ s: TodaySummary) -> some View {
        if !s.suggestions.isEmpty {
            section("TO-DOS WITHOUT A TIME") {
                ForEach(Array(s.suggestions.enumerated()), id: \.element.id) { i, sug in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sug.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            Text(sug.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(ReminderFormat.short(sug.slot)).font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Accept") { accept([sug]) }.buttonStyle(Pill())
                        ReminderButton(title: sug.title, target: sug.target, label: "Other time")
                    }.padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle()).onTapGesture { ws.open(sug.target) }
                    Divider().opacity(0.6)
                }
                HStack { Spacer(); Button("Accept all \(s.suggestions.count)") { accept(s.suggestions) }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent) }.padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    // MARK: Actions

    private func accept(_ list: [TodaySuggestion]) {
        for s in list { ws.addReminder(title: s.title, when: s.slot, target: s.target) }
        if !list.isEmpty { AppModel.shared.show("Set \(list.count) reminder\(list.count == 1 ? "" : "s").") }
    }

    private func deadlinesWithoutReminder(_ s: TodaySummary) -> [TodayItem] { s.schedule.filter { $0.kind == .deadline && ws.reminders(for: $0.target).isEmpty } }

    /// A deadline without a time gets a reminder at 16:00 that day, or in an hour if that has passed.
    private func remindDeadlines(_ s: TodaySummary) {
        let cal = Calendar.current
        let list = deadlinesWithoutReminder(s)
        for item in list {
            let four = cal.date(bySettingHour: 16, minute: 0, second: 0, of: item.when) ?? item.when
            ws.addReminder(title: item.title, when: four > .now ? four : Date().addingTimeInterval(3600), target: item.target)
        }
        if !list.isEmpty { AppModel.shared.show("Added \(list.count) reminder\(list.count == 1 ? "" : "s").") }
    }

    private func planDay() {
        accept(summary.suggestions)
        Task { await model.refresh(facts: summary.text()) }
    }
}
