// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Something to be reminded of, and where it points. Stored in `reminders.json` beside the pages so it syncs and diffs like them.
public struct Reminder: Identifiable, Equatable, Codable, Sendable {
    public struct Target: Equatable, Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case block, row, task, none }
        public var kind: Kind
        public var a: String          // page, database or plan id
        public var b: String          // block, row or task id
        public init(kind: Kind = .none, a: String = "", b: String = "") { self.kind = kind; self.a = a; self.b = b }
        public static let none = Target()
    }
    public var id: String
    public var title: String
    public var when: Date
    public var target: Target
    public var done: Bool
    public var nudge: Bool            // remind again two hours later if still open
    public var created: Date
    public init(id: String = UUID().uuidString, title: String, when: Date, target: Target = .none, done: Bool = false, nudge: Bool = false, created: Date = Date()) {
        self.id = id; self.title = title; self.when = when; self.target = target; self.done = done; self.nudge = nudge; self.created = created
    }
}

/// Picks times for reminders. Local and predictable: working hours, half-hour slots, weekdays, never on top of another reminder.
public enum ReminderPlanner {
    static let firstHour = 9, lastSlotHour = 17          // last slot starts at 17:30

    /// The next free slot after `now`. `taken` are times already booked; a slot within 30 minutes of one is skipped.
    public static func suggest(after now: Date, taken: [Date], calendar: Calendar = .current) -> Date {
        var cursor = nextHalfHour(after: now.addingTimeInterval(15 * 60), calendar: calendar)
        for _ in 0..<(14 * 20) {
            if isWorkSlot(cursor, calendar), !taken.contains(where: { abs($0.timeIntervalSince(cursor)) < 30 * 60 }) { return cursor }
            cursor = cursor.addingTimeInterval(30 * 60)
        }
        return cursor
    }

    static func isWorkSlot(_ d: Date, _ cal: Calendar) -> Bool {
        let c = cal.dateComponents([.hour, .minute, .weekday], from: d)
        guard let h = c.hour, let w = c.weekday, !(w == 1 || w == 7) else { return false }
        return h >= firstHour && (h < lastSlotHour || (h == lastSlotHour && (c.minute ?? 0) <= 30))
    }

    static func nextHalfHour(after d: Date, calendar: Calendar) -> Date {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        var out = calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: (c.minute ?? 0) < 30 ? 30 : 60)) ?? d
        if out <= d { out = out.addingTimeInterval(30 * 60) }
        return out
    }

    /// The fixed choices in the Remind me menu.
    public static func quickOptions(now: Date, calendar: Calendar = .current) -> [(label: String, date: Date)] {
        let hour = now.addingTimeInterval(3600)
        var out: [(String, Date)] = [("In 1 hour", hour)]
        func at9(_ d: Date) -> Date { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d }
        let tomorrow = at9(calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        out.append(("Tomorrow morning", tomorrow))
        if let monday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime) { out.append(("Next week", monday)) }
        return out
    }
}

/// What the Today view shows, worked out from the whole workspace. Pure, so it can be tested and handed to an AI as facts.
public struct TodayItem: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case reminder, deadline }
    public var id: String
    public var title: String
    public var detail: String          // where it lives, "Task, Launch plan"
    public var when: Date
    public var timed: Bool             // false: a date with no time of day
    public var kind: Kind
    public var overdueDays: Int        // 0 when not overdue
    public var target: Reminder.Target
}

public struct TodaySuggestion: Identifiable, Equatable, Sendable {
    public var id: String { target.b }
    public var title: String
    public var detail: String
    public var target: Reminder.Target
    public var slot: Date
}

public struct TodaySummary: Equatable, Sendable {
    public var schedule: [TodayItem] = []
    public var overdue: [TodayItem] = []
    public var attention: [String: String] = [:]        // headline to detail, for people over capacity and tasks at risk
    public var attentionOrder: [String] = []
    public var suggestions: [TodaySuggestion] = []
    public var dueToday = 0
    public var remindersToday = 0
    public var badge: Int { dueToday + overdue.count }
}

public enum TodayPlan {
    static func isDone(_ s: String) -> Bool { StatusTone.of(s) == .done }

    public static func build(pages: [Page], databases: [Database], plans: [Plan], reminders: [Reminder], now: Date = Date(), windowDays: Int = 1, calendar cal: Calendar = .current) -> TodaySummary {
        var out = TodaySummary()
        let today = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: windowDays, to: today) ?? today.addingTimeInterval(86400)
        func daysLate(_ d: Date) -> Int { cal.dateComponents([.day], from: cal.startOfDay(for: d), to: today).day ?? 0 }

        var all: [TodayItem] = []
        for r in reminders where !r.done {
            let late = r.when < today ? daysLate(r.when) : 0
            all.append(TodayItem(id: "r-\(r.id)", title: r.title, detail: "Reminder", when: r.when, timed: true, kind: .reminder, overdueDays: late, target: r.target))
        }
        for p in plans {
            for t in p.tasks where t.status != .completed && t.status != .archived {
                let last = cal.date(byAdding: .day, value: -1, to: t.end) ?? t.end      // end is exclusive
                all.append(TodayItem(id: "t-\(t.id)", title: t.name, detail: "Task, \(p.title)", when: cal.startOfDay(for: last), timed: false, kind: .deadline,
                                     overdueDays: last < today ? daysLate(last) : 0, target: .init(kind: .task, a: p.id, b: t.id)))
            }
            let report = PlanMath.report(p, now: now)
            for name in report.overloaded { out.add("\(name) is over capacity", "\(p.title). Move a task or add a person") }
            for t in p.tasks where t.status == .atRisk { out.add("\(t.name) is at risk", p.title) }
        }
        for d in databases {
            guard let dateCol = d.columns.first(where: { $0.kind == .date }) else { continue }
            let statusCol = d.columns.first { $0.kind == .status }
            for r in d.rows {
                guard let due = CellDate.parse(r.cells[dateCol.id] ?? ""), !(statusCol.map { isDone(r.cells[$0.id] ?? "") } ?? false) else { continue }
                let name = r.cells[d.columns.first?.id ?? "name"] ?? ""
                guard !name.isEmpty else { continue }
                all.append(TodayItem(id: "d-\(r.id)", title: name, detail: "Row, \(d.title)", when: cal.startOfDay(for: due), timed: false, kind: .deadline,
                                     overdueDays: due < today ? daysLate(due) : 0, target: .init(kind: .row, a: d.id, b: r.id)))
            }
        }

        out.overdue = all.filter { $0.overdueDays > 0 }.sorted { $0.overdueDays > $1.overdueDays }
        out.schedule = all.filter { $0.overdueDays == 0 && $0.when >= today && $0.when < end }.sorted { ($0.when, $0.timed ? 0 : 1) < ($1.when, $1.timed ? 0 : 1) }
        out.dueToday = out.schedule.filter { $0.kind == .deadline && cal.isDate($0.when, inSameDayAs: today) }.count
        out.remindersToday = out.schedule.filter { $0.kind == .reminder && cal.isDate($0.when, inSameDayAs: today) }.count

        // To-dos with no reminder yet get a suggested time, so the day can be planned in one click.
        let remindered = Set(reminders.filter { !$0.done && $0.target.kind == .block }.map(\.target.b))
        var taken = reminders.filter { !$0.done }.map(\.when)
        for p in pages.sorted(by: { $0.updated > $1.updated }) {
            for b in p.blocks where b.kind == .todo && !b.checked && !b.text.isEmpty && !remindered.contains(b.id) {
                guard out.suggestions.count < 6 else { break }
                let slot = ReminderPlanner.suggest(after: now, taken: taken, calendar: cal)
                taken.append(slot)
                out.suggestions.append(TodaySuggestion(title: InlineMarkdown.plain(b.text), detail: p.title, target: .init(kind: .block, a: p.id, b: b.id), slot: slot))
            }
        }
        return out
    }
}

extension TodaySummary {
    mutating func add(_ headline: String, _ detail: String) {
        guard attention[headline] == nil else { return }
        attention[headline] = detail; attentionOrder.append(headline)
    }

    /// Plain text for a stand-up note or an AI prompt.
    public func text(now: Date = Date()) -> String {
        var lines: [String] = []
        if !overdue.isEmpty { lines.append("Overdue:"); lines += overdue.map { "- \($0.title) (\($0.detail), \($0.overdueDays) day\($0.overdueDays == 1 ? "" : "s") late)" } }
        if !schedule.isEmpty {
            lines.append("Coming up:")
            let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"
            lines += schedule.map { "- \($0.title) (\($0.detail)\($0.timed ? ", " + f.string(from: $0.when) : ", due that day"))" }
        }
        if !attentionOrder.isEmpty { lines.append("Needs attention:"); lines += attentionOrder.map { "- \($0): \(attention[$0] ?? "")" } }
        if !suggestions.isEmpty { lines.append("To-dos without a time:"); lines += suggestions.map { "- \($0.title) (\($0.detail))" } }
        return lines.isEmpty ? "Nothing is due." : lines.joined(separator: "\n")
    }
}

/// Asks the user's own `claude` command for a short spoken-style briefing. Runs only when the user asks.
public enum AIBriefing {
    public static func prompt(_ facts: String) -> String {
        """
        Write a short briefing for my day, at most 60 words, plain sentences, no lists, no markdown. Say what is pressing first, then what needs a date or attention. Use only the facts below and invent nothing.

        \(facts.prefix(6000))
        """
    }
    public static func run(facts: String) async throws -> String {
        guard AIOrganizer.available else { throw ShellError.failed(command: "claude", status: 1, stderr: "Claude Code is not installed, so there is no summary to write.") }
        let out = try await Shell.check("claude", ["-p", prompt(facts)], cwd: FileManager.default.temporaryDirectory, timeout: 90)
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ShellError.failed(command: "claude", status: 1, stderr: "Claude Code sent back nothing.") }
        return text
    }
}
