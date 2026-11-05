// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AntslyKit

enum ReminderFormat {
    /// "Today 16:00", "Tomorrow 09:00", "Fri 10:00", or "12 Nov 09:00" when it is further off.
    static func short(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDate(d, inSameDayAs: now) { return "Today \(time)" }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "Tomorrow \(time)" }
        if d > now, d.timeIntervalSince(now) < 6 * 86400 { return "\(d.formatted(.dateTime.weekday(.abbreviated))) \(time)" }
        return "\(d.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }
}

/// A bell that opens the reminder menu. Shows the next reminder's time when there is one, so anything with a reminder says so.
struct ReminderButton: View {
    let title: String
    let target: Reminder.Target
    var startWithPicker = false
    var label: String?                    // text instead of the bell, for places with room
    var compact = false                   // bell only, never the time
    @State private var open = false
    let ws = WorkspaceModel.shared

    var body: some View {
        let existing = ws.reminders(for: target)
        Button { open = true } label: {
            if let label { Text(label).font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle()) }
            else {
                HStack(spacing: 4) {
                    Image(systemName: existing.isEmpty ? "bell" : "bell.fill").font(.system(size: 11.5))
                    if !compact, let next = existing.first { Text(ReminderFormat.short(next.when)).font(.system(size: 11.5)) }
                }.foregroundStyle(existing.isEmpty ? Color.secondary : Theme.accent).frame(minWidth: 22, minHeight: 22).contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain).help(existing.isEmpty ? "Remind me" : "Reminders").accessibilityLabel(existing.isEmpty ? "Remind me" : "Reminders")
        .popover(isPresented: $open, arrowEdge: .bottom) { ReminderPicker(title: title, target: target, startWithPicker: startWithPicker) { open = false } }
    }
}

/// The Remind me menu: what is already set, a suggested time, a few quick times, and any date and time.
struct ReminderPicker: View {
    let title: String
    let target: Reminder.Target
    var startWithPicker = false
    var done: () -> Void
    @State private var custom = Date()
    @State private var showCustom = false
    @State private var nudge = true
    let ws = WorkspaceModel.shared

    private var suggested: Date { ReminderPlanner.suggest(after: .now, taken: ws.reminders.filter { !$0.done }.map(\.when)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            let existing = ws.reminders(for: target)
            if !existing.isEmpty {
                SectionLabel("Set").padding(.horizontal, 8)
                ForEach(existing) { r in
                    HStack(spacing: 6) {
                        Image(systemName: "bell.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
                        Text(ReminderFormat.short(r.when)).font(.system(size: 13))
                        Spacer()
                        Button("Done") { ws.finishReminder(r.id) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                        Button("Remove") { ws.removeReminder(r.id) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 8).padding(.vertical, 4)
                }
                Divider().padding(.vertical, 4)
            }
            SectionLabel("Remind me").padding(.horizontal, 8).padding(.top, 2)
            option(ReminderFormat.short(suggested), "Suggested", icon: "sparkles", tint: true) { add(suggested) }
            Text("The next free half hour in working hours.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.bottom, 4)
            ForEach(Array(ReminderPlanner.quickOptions(now: .now).enumerated()), id: \.offset) { _, o in
                option(o.label, ReminderFormat.short(o.date)) { add(o.date) }
            }
            Divider().padding(.vertical, 4)
            if showCustom || startWithPicker {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("", selection: $custom, in: Date()...).labelsHidden().datePickerStyle(.compact)
                    Button("Set reminder") { add(custom) }.buttonStyle(Pill(kind: .primary))
                }.padding(.horizontal, 8).padding(.vertical, 4)
            } else {
                option("Pick a date and time…", "") { showCustom = true }
            }
            Divider().padding(.vertical, 4)
            Toggle("Remind me again if it is still open", isOn: $nudge).toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
        }
        .padding(8).frame(width: 300)
        .onAppear { custom = suggested; if startWithPicker { showCustom = true } }
    }

    private func option(_ text: String, _ detail: String, icon: String? = nil, tint: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon ?? "circle").font(.system(size: 11)).opacity(icon == nil ? 0 : 1).foregroundStyle(Theme.accent).frame(width: 14)
                Text(text).font(.system(size: 13))
                Spacer()
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }.padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity).background(tint ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func add(_ when: Date) {
        ws.addReminder(title: title, when: when, target: target, nudge: nudge)
        AppModel.shared.show("Reminder set for \(ReminderFormat.short(when)).")
        done()
    }
}
