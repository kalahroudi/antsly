// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A project plan: phases, tasks with dated ranges and per-person allocations, people with capacity, and dated progress snapshots.
/// Stored as one JSON file per plan so it diffs, merges and syncs like pages.
public struct Plan: Identifiable, Equatable, Codable, Sendable {
    public enum Unit: String, Codable, Sendable, CaseIterable { case personDays, storyPoints, tasks }
    public enum Status: String, Codable, Sendable, CaseIterable { case notStarted, inProgress, completed, atRisk, archived }

    public struct Phase: Identifiable, Equatable, Codable, Sendable { public var id: String; public var name: String; public var color: String
        public init(id: String = UUID().uuidString, name: String, color: String) { self.id = id; self.name = name; self.color = color } }

    public struct Person: Identifiable, Equatable, Codable, Sendable {
        public var id: String; public var name: String
        public var daysPerWeek: Double            // capacity, normally 5
        public var daysOff: [DayRange]            // holidays and leave
        public init(id: String = UUID().uuidString, name: String, daysPerWeek: Double = 5, daysOff: [DayRange] = []) { self.id = id; self.name = name; self.daysPerWeek = daysPerWeek; self.daysOff = daysOff }
    }
    public struct DayRange: Equatable, Codable, Sendable { public var start: Date; public var end: Date
        public init(start: Date, end: Date) { self.start = start; self.end = end } }

    public struct Assignment: Equatable, Codable, Sendable { public var personID: String; public var daysPerWeek: Double
        public init(personID: String, daysPerWeek: Double = 1.5) { self.personID = personID; self.daysPerWeek = daysPerWeek } }

    public struct Task: Identifiable, Equatable, Codable, Sendable {
        public var id: String; public var phaseID: String; public var name: String
        public var start: Date; public var end: Date              // end is exclusive
        public var assignments: [Assignment]
        public var status: Status; public var progress: Double    // 0...1
        public var critical: Bool; public var milestone: Bool
        public var dependsOn: [String]
        public var points: Double?                                // story points, when the plan counts in points
        public var externalRef: String?                           // "jira:ABC-123", "github:owner/repo#42"
        public init(id: String = UUID().uuidString, phaseID: String, name: String, start: Date, end: Date, assignments: [Assignment] = [], status: Status = .notStarted,
                    progress: Double = 0, critical: Bool = false, milestone: Bool = false, dependsOn: [String] = [], points: Double? = nil, externalRef: String? = nil) {
            self.id = id; self.phaseID = phaseID; self.name = name; self.start = start; self.end = end; self.assignments = assignments; self.status = status
            self.progress = progress; self.critical = critical; self.milestone = milestone; self.dependsOn = dependsOn; self.points = points; self.externalRef = externalRef
        }
    }
    /// One dated reading of scope and completed work, so the burnup shows real history, not an estimate.
    public struct Snapshot: Equatable, Codable, Sendable { public var date: Date; public var scope: Double; public var completed: Double
        public init(date: Date, scope: Double, completed: Double) { self.date = date; self.scope = scope; self.completed = completed } }

    public var id: String
    public var title: String
    public var unit: Unit
    public var phases: [Phase]
    public var people: [Person]
    public var tasks: [Task]
    public var snapshots: [Snapshot]
    public var notes: String

    public init(id: String = UUID().uuidString, title: String, unit: Unit = .personDays, phases: [Phase] = [], people: [Person] = [], tasks: [Task] = [], snapshots: [Snapshot] = [], notes: String = "") {
        self.id = id; self.title = title; self.unit = unit; self.phases = phases; self.people = people; self.tasks = tasks; self.snapshots = snapshots; self.notes = notes
    }
}

public enum PlanMath {
    static let day: TimeInterval = 86_400
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 2; return c }

    /// Days of overlap between [a, b) and [c, d).
    static func overlapDays(_ a: Date, _ b: Date, _ c: Date, _ d: Date) -> Double {
        max(0, min(b, d).timeIntervalSince(max(a, c))) / day
    }

    /// Work needed by a task in person-days: allocation (days per week) times its length in weeks, summed over people.
    public static func effort(_ t: Plan.Task) -> Double {
        let weeks = t.end.timeIntervalSince(t.start) / day / 7
        return t.assignments.reduce(0) { $0 + $1.daysPerWeek * weeks }
    }

    /// The size of a task in the plan's unit.
    public static func size(_ t: Plan.Task, unit: Plan.Unit) -> Double {
        switch unit { case .personDays: effort(t); case .storyPoints: t.points ?? 0; case .tasks: 1 }
    }

    /// Booked share of one person's capacity over [a, b): 1.0 is fully booked, above 1.0 is overloaded. Days off reduce capacity.
    public static func utilization(person: Plan.Person, in plan: Plan, from a: Date, to b: Date) -> Double {
        let weeks = b.timeIntervalSince(a) / day / 7
        guard weeks > 0 else { return 0 }
        var booked = 0.0
        for t in plan.tasks {
            guard let asg = t.assignments.first(where: { $0.personID == person.id }) else { continue }
            let len = t.end.timeIntervalSince(t.start) / day
            guard len > 0 else { continue }
            booked += asg.daysPerWeek * (overlapDays(a, b, t.start, t.end) / 7)
        }
        let offDays = person.daysOff.reduce(0.0) { $0 + overlapDays(a, b, $1.start, $1.end) } * (person.daysPerWeek / 7)
        let capacity = max(0.0001, person.daysPerWeek * weeks - offDays)
        return booked / capacity
    }

    /// The chain of dependent tasks that determines the finish date. Falls back to the tasks flagged critical by hand when there are no dependencies.
    public static func criticalPath(_ plan: Plan) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: plan.tasks.map { ($0.id, $0) })
        var memo: [String: (len: TimeInterval, path: [String])] = [:]
        func best(_ id: String, _ seen: Set<String>) -> (len: TimeInterval, path: [String]) {
            if let m = memo[id] { return m }
            guard let t = byID[id], !seen.contains(id) else { return (0, []) }
            let dur = t.end.timeIntervalSince(t.start)
            let pre = t.dependsOn.map { best($0, seen.union([id])) }.max { $0.len < $1.len } ?? (0, [])
            let r = (pre.len + dur, pre.path + [id]); memo[id] = r; return r
        }
        guard plan.tasks.contains(where: { !$0.dependsOn.isEmpty }) else { return plan.tasks.filter(\.critical).map(\.id) }
        return plan.tasks.map { best($0.id, []) }.max { $0.len < $1.len }?.path ?? []
    }

    public struct BurnPoint: Equatable, Sendable { public var date: Date; public var scope: Double; public var planned: Double; public var completed: Double? }

    /// Burnup sampled at the given dates. Planned is each task's size spread evenly across its dates. Completed uses recorded snapshots
    /// (the latest at or before the date); with no snapshot yet it falls back to size times progress at `now`.
    public static func burnup(_ plan: Plan, at dates: [Date], now: Date) -> [BurnPoint] {
        let u = plan.unit
        let snaps = plan.snapshots.sorted { $0.date < $1.date }
        func planned(_ d: Date) -> Double {
            plan.tasks.reduce(0) { s, t in
                let len = t.end.timeIntervalSince(t.start); guard len > 0 else { return s + (d >= t.end ? size(t, unit: u) : 0) }
                return s + size(t, unit: u) * min(1, max(0, d.timeIntervalSince(t.start) / len))
            }
        }
        let total = plan.tasks.reduce(0) { $0 + size($1, unit: u) }
        return dates.map { d in
            let snap = snaps.last { $0.date <= d }
            let completed: Double? = d > now ? nil : (snap?.completed ?? (d == now || snaps.isEmpty ? plan.tasks.reduce(0) { $0 + size($1, unit: u) * ($1.status == .completed ? 1 : $1.progress) } : nil))
            return BurnPoint(date: d, scope: snap?.scope ?? total, planned: planned(d), completed: completed)
        }
    }

    /// Records today's scope and completed work. Call once a day at most; replaces an existing reading for the same day.
    public static func snapshot(_ plan: Plan, now: Date) -> Plan {
        var p = plan
        let u = p.unit
        let scope = p.tasks.reduce(0) { $0 + size($1, unit: u) }
        let done = p.tasks.reduce(0) { $0 + size($1, unit: u) * ($1.status == .completed ? 1 : $1.progress) }
        let dayStart = cal.startOfDay(for: now)
        p.snapshots.removeAll { cal.startOfDay(for: $0.date) == dayStart }
        p.snapshots.append(Plan.Snapshot(date: now, scope: scope, completed: done))
        return p
    }

    public struct Report: Equatable, Sendable {
        public var total: Int, completed: Int, inProgress: Int, atRisk: Int, critical: Int
        public var phaseProgress: [(name: String, percent: Int)]
        public var overloaded: [String]
        public var criticalPath: [String]
        public var upcoming: [String]
        public static func == (l: Report, r: Report) -> Bool { l.total == r.total && l.completed == r.completed && l.atRisk == r.atRisk && l.overloaded == r.overloaded }
    }

    public static func report(_ plan: Plan, now: Date, horizonDays: Double = 92) -> Report {
        let done = plan.tasks.filter { $0.status == .completed }.count
        let phaseProgress = plan.phases.map { ph -> (String, Int) in
            let ts = plan.tasks.filter { $0.phaseID == ph.id }
            guard !ts.isEmpty else { return (ph.name, 0) }
            return (ph.name, Int((ts.reduce(0) { $0 + ($1.status == .completed ? 1 : $1.progress) } / Double(ts.count) * 100).rounded()))
        }
        let end = now.addingTimeInterval(horizonDays * day)
        let overloaded = plan.people.filter { utilization(person: $0, in: plan, from: now, to: end) > 1 }.map(\.name)
        let names = Dictionary(uniqueKeysWithValues: plan.tasks.map { ($0.id, $0.name) })
        return Report(total: plan.tasks.count, completed: done, inProgress: plan.tasks.filter { $0.status == .inProgress }.count,
                      atRisk: plan.tasks.filter { $0.status == .atRisk }.count, critical: plan.tasks.filter(\.critical).count,
                      phaseProgress: phaseProgress, overloaded: overloaded, criticalPath: criticalPath(plan).compactMap { names[$0] },
                      upcoming: plan.tasks.filter { $0.start >= now && $0.start < end }.map(\.name))
    }

    /// Plain Markdown for "Copy Markdown" and "Save as page".
    public static func markdown(_ plan: Plan, report r: Report, now: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeZone = TimeZone(identifier: "UTC")
        var s = "# \(plan.title): status report\n\n\(f.string(from: now))\n\n"
        s += "- \(r.total) tasks: \(r.completed) completed, \(r.inProgress) in progress, \(r.atRisk) at risk, \(r.critical) on the critical path\n\n## Progress by phase\n\n"
        for p in r.phaseProgress { s += "- \(p.name): \(p.percent)%\n" }
        if !r.criticalPath.isEmpty { s += "\n## Critical path\n\n" + r.criticalPath.joined(separator: " → ") + "\n" }
        if !r.overloaded.isEmpty { s += "\n## Overloaded next quarter\n\n" + r.overloaded.joined(separator: ", ") + "\n" }
        if !r.upcoming.isEmpty { s += "\n## Starting soon\n\n" + r.upcoming.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return s
    }
}

/// Reads a Gantt Magic backup (the data model of github.com/kalahroudi/vmo2_planning): quarters, phases, actors and tasks with quarter indices.
public enum GanttMagicImport {
    public enum Failure: Error { case notGanttMagic }

    public static func parse(_ json: Data) throws -> Plan {
        guard let o = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let quarters = o["quarters"] as? [[String: Any]], let phases = o["phases"] as? [[String: Any]], let tasks = o["tasks"] as? [[String: Any]] else { throw Failure.notGanttMagic }
        func qStart(_ i: Int) -> Date {
            let q = quarters[min(max(i, 0), quarters.count - 1)]
            let y = q["year"] as? Int ?? 2026, n = q["q"] as? Int ?? 1
            return PlanMath.cal.date(from: DateComponents(year: y, month: (n - 1) * 3 + 1, day: 1))!
        }
        func qEnd(_ i: Int) -> Date { PlanMath.cal.date(byAdding: .month, value: 3, to: qStart(i))! }
        let ph = phases.compactMap { p -> Plan.Phase? in
            guard let id = p["id"] as? String, let n = p["name"] as? String else { return nil }
            return Plan.Phase(id: id, name: n, color: (p["color"] as? String) ?? "#6B7280")
        }
        let actorNames = (o["actors"] as? [String]) ?? Array(Set(tasks.flatMap { ($0["actors"] as? [String]) ?? [] })).sorted()
        let people = actorNames.map { Plan.Person(id: $0, name: $0) }
        func status(_ s: String?, _ done: Bool) -> Plan.Status {
            switch s { case "completed": .completed; case "at-risk": .atRisk; case "in-progress": .inProgress; case "archived": .archived; default: .notStarted }
        }
        let out = tasks.compactMap { t -> Plan.Task? in
            guard let id = t["id"] as? String, let pid = t["phaseId"] as? String, let n = t["name"] as? String, let s = t["start"] as? Int, let e = t["end"] as? Int else { return nil }
            let st = status(t["status"] as? String, false)
            return Plan.Task(id: id, phaseID: pid, name: n, start: qStart(s), end: qEnd(e),
                             assignments: ((t["actors"] as? [String]) ?? []).map { Plan.Assignment(personID: $0) },
                             status: st, progress: st == .completed ? 1 : 0, critical: (t["critical"] as? Bool) ?? false)
        }
        return Plan(title: (o["title"] as? String) ?? "Imported plan", phases: ph, people: people, tasks: out, notes: (o["footnote"] as? String) ?? "")
    }
}
