import XCTest
@testable import AntslyKit

final class PlanTests: XCTestCase {
    func d(_ y: Int, _ m: Int, _ day: Int = 1) -> Date { PlanMath.cal.date(from: DateComponents(year: y, month: m, day: day))! }

    func plan() -> Plan {
        let mo = Plan.Person(id: "mo", name: "Mo"), dan = Plan.Person(id: "dan", name: "Dan", daysOff: [.init(start: d(2026, 1, 1), end: d(2026, 1, 15))])
        let a = Plan.Task(id: "a", phaseID: "p", name: "A", start: d(2026, 1), end: d(2026, 1, 29), assignments: [.init(personID: "mo", daysPerWeek: 2.5)], critical: true)
        let b = Plan.Task(id: "b", phaseID: "p", name: "B", start: d(2026, 1, 29), end: d(2026, 2, 26), assignments: [.init(personID: "mo", daysPerWeek: 5), .init(personID: "dan", daysPerWeek: 2)], dependsOn: ["a"])
        let c = Plan.Task(id: "c", phaseID: "p", name: "C", start: d(2026, 1), end: d(2026, 1, 8), dependsOn: [])
        return Plan(id: "x", title: "T", phases: [.init(id: "p", name: "Phase", color: "#000")], people: [mo, dan], tasks: [a, b, c])
    }

    func testEffortIsAllocationTimesWeeks() {
        let p = plan()
        XCTAssertEqual(PlanMath.effort(p.tasks[0]), 10, accuracy: 0.001)       // 2.5 d/wk x 4 weeks
        XCTAssertEqual(PlanMath.effort(p.tasks[1]), 28, accuracy: 0.001)       // (5 + 2) x 4 weeks
    }

    func testUtilizationFlagsOverloadAndRespectsDaysOff() {
        let p = plan()
        XCTAssertEqual(PlanMath.utilization(person: p.people[0], in: p, from: d(2026, 1), to: d(2026, 1, 29)), 0.5, accuracy: 0.001)
        XCTAssertEqual(PlanMath.utilization(person: p.people[0], in: p, from: d(2026, 1, 29), to: d(2026, 2, 26)), 1.0, accuracy: 0.001)
        var over = p; over.tasks[1].assignments[0].daysPerWeek = 6
        XCTAssertGreaterThan(PlanMath.utilization(person: over.people[0], in: over, from: d(2026, 1, 29), to: d(2026, 2, 26)), 1)
        // Dan has two weeks off, so the same booking uses more of what is left than it would at full capacity.
        let full = PlanMath.utilization(person: .init(name: "x"), in: p, from: d(2026, 1, 29), to: d(2026, 2, 26))
        XCTAssertEqual(full, 0)
    }

    func testCriticalPathFollowsDependencies() {
        XCTAssertEqual(PlanMath.criticalPath(plan()), ["a", "b"])
        var flat = plan(); flat.tasks[1].dependsOn = []
        XCTAssertEqual(PlanMath.criticalPath(flat), ["a"])             // falls back to hand-flagged tasks
    }

    func testBurnupUsesSnapshotsAndStopsAtNow() {
        var p = plan(); p.tasks[0].status = .completed
        let now = d(2026, 1, 29)
        let pts = PlanMath.burnup(p, at: [d(2026, 1, 15), now, d(2026, 2, 12)], now: now)
        XCTAssertEqual(pts[0].scope, 38 + 0, accuracy: 0.001 + 0)     // 10 + 28 + 0
        XCTAssertNotNil(pts[1].completed); XCTAssertEqual(pts[1].completed!, 10, accuracy: 0.001)
        XCTAssertNil(pts[2].completed)
        XCTAssertEqual(pts[1].planned, 10, accuracy: 0.001)
        let snapped = PlanMath.snapshot(p, now: now)
        XCTAssertEqual(snapped.snapshots.count, 1)
        XCTAssertEqual(PlanMath.snapshot(snapped, now: now.addingTimeInterval(3600)).snapshots.count, 1)  // same day replaces
    }

    func testUnitsChangeTheSizeOfWork() {
        var p = plan(); p.tasks[0].points = 8
        XCTAssertEqual(PlanMath.size(p.tasks[0], unit: .storyPoints), 8); XCTAssertEqual(PlanMath.size(p.tasks[1], unit: .storyPoints), 0)
        XCTAssertEqual(PlanMath.size(p.tasks[0], unit: .tasks), 1)
    }

    func testReportAndMarkdown() {
        var p = plan(); p.tasks[0].status = .completed; p.tasks[1].status = .atRisk
        let r = PlanMath.report(p, now: d(2026, 1, 20))
        XCTAssertEqual(r.total, 3); XCTAssertEqual(r.completed, 1); XCTAssertEqual(r.atRisk, 1); XCTAssertEqual(r.criticalPath, ["A", "B"])
        XCTAssertTrue(PlanMath.markdown(p, report: r, now: d(2026, 1, 20)).contains("A → B"))
    }

    func testPlanFileRoundTripAndGanttMagicImport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("antsly-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkspaceStore(root: dir); try s.save(plan())
        XCTAssertEqual(s.loadPlans().first, plan())
        let gm = ##"{"quarters":[{"year":2026,"q":2},{"year":2026,"q":3}],"phases":[{"id":"p","name":"One","color":"#2563EB"}],"actors":["Mo","Dan"],"tasks":[{"id":"t1","phaseId":"p","name":"Do it","actors":["Mo"],"start":0,"end":1,"critical":true,"status":"at-risk"}],"footnote":"note"}"##
        let imp = try GanttMagicImport.parse(Data(gm.utf8))
        XCTAssertEqual(imp.people.map(\.name), ["Mo", "Dan"]); XCTAssertEqual(imp.tasks[0].status, .atRisk); XCTAssertTrue(imp.tasks[0].critical)
        XCTAssertEqual(imp.tasks[0].start, d(2026, 4)); XCTAssertEqual(imp.tasks[0].end, d(2026, 10))
        XCTAssertThrowsError(try GanttMagicImport.parse(Data("{}".utf8)))
    }
}

final class AllocationTests: XCTestCase {
    func d(_ y: Int, _ m: Int, _ day: Int = 1) -> Date { PlanMath.cal.date(from: DateComponents(year: y, month: m, day: day))! }

    func plan() -> Plan {
        let mo = Plan.Person(id: "mo", name: "Mo"), dan = Plan.Person(id: "dan", name: "Dan")
        let p1 = Plan.Phase(id: "p1", name: "Build", color: "#111"), p2 = Plan.Phase(id: "p2", name: "Ship", color: "#222")
        let a = Plan.Task(id: "a", phaseID: "p1", name: "A", start: d(2026, 1), end: d(2026, 1, 29), assignments: [.init(personID: "mo", daysPerWeek: 2.5)])      // 4 weeks: 10 person-days
        let b = Plan.Task(id: "b", phaseID: "p1", name: "B", start: d(2026, 1), end: d(2026, 1, 29), assignments: [.init(personID: "mo", daysPerWeek: 3), .init(personID: "dan", daysPerWeek: 1)])  // Mo 12, Dan 4
        let c = Plan.Task(id: "c", phaseID: "p2", name: "C", start: d(2026, 2), end: d(2026, 2, 26), assignments: [.init(personID: "dan", daysPerWeek: 2)])
        return Plan(id: "x", title: "T", phases: [p1, p2], people: [mo, dan], tasks: [a, b, c])
    }

    func testTotalsSharesAndMatrix() {
        let a = PlanMath.allocation(plan())
        XCTAssertEqual(a.total, 10 + 16 + 25.0 / 7 * 2, accuracy: 0.001)         // A 10, B 16, C is 25 days at 2 days a week
        XCTAssertEqual(a.phases[0].personDays, 26, accuracy: 0.001)
        XCTAssertEqual(a.phases[0].people.first?.name, "Mo"); XCTAssertEqual(a.phases[0].people.first!.days, 22, accuracy: 0.001)
        XCTAssertEqual(a.matrix["Dan"]?["p1"] ?? 0, 4, accuracy: 0.001)
        XCTAssertEqual(a.phases.map(\.share).reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertEqual(a.top?.name, "Mo"); XCTAssertEqual(a.peopleCount, 2)
    }

    func testOverloadFlagPerPhase() {
        let a = PlanMath.allocation(plan())
        // Mo has 2.5 + 3 = 5.5 days per week in Build, so 110% of a 5 day week.
        XCTAssertEqual(a.phases[0].overloaded.map(\.name), ["Mo"])
        XCTAssertEqual(a.phases[0].overloaded.first!.days, 110, accuracy: 1)
        XCTAssertTrue(a.phases[1].overloaded.isEmpty)
    }

    func testMarkdownContainsTablesAndFlags() {
        let p = plan()
        let md = PlanMath.markdown(p, report: PlanMath.report(p, now: d(2026, 1, 10)), now: d(2026, 1, 10))
        XCTAssertTrue(md.contains("## Resource allocation")); XCTAssertTrue(md.contains("| Build |"))
        XCTAssertTrue(md.contains("Mo reaches 110% during Build")); XCTAssertTrue(md.contains("By person and phase"))
    }
}
