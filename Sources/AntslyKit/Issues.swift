// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct Issue: Equatable, Sendable, Identifiable {
    public var number: Int
    public var title: String
    public var state: String           // "open" or "closed"
    public var assignee: String
    public var labels: [String]
    public var id: Int { number }
}

/// GitHub issues as a database, two ways, through the user's own `gh` sign-in. Antsly never sees a password or token.
public enum GitHubIssues {
    public static func parse(_ json: Data) -> [Issue] {
        guard let arr = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let n = o["number"] as? Int, let t = o["title"] as? String else { return nil }
            let assignees = (o["assignees"] as? [[String: Any]])?.compactMap { $0["login"] as? String } ?? []
            let labels = (o["labels"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            return Issue(number: n, title: t, state: ((o["state"] as? String) ?? "open").lowercased(), assignee: assignees.first ?? "", labels: labels)
        }.sorted { $0.number > $1.number }
    }

    public static func database(repo: String, issues: [Issue], existing: Database? = nil) -> Database {
        var db = existing ?? Database(title: "Issues", columns: [.init(id: "number", name: "#"), .init(id: "name", name: "Issue"), .init(id: "status", name: "Status"),
                                                                 .init(id: "owner", name: "Assignee"), .init(id: "labels", name: "Labels")], groupBy: "status", source: "github:\(repo)")
        db.rows = issues.map { i in
            Database.Row(id: "gh-\(i.number)", cells: ["number": "\(i.number)", "name": i.title, "status": i.state == "open" ? "Open" : "Closed", "owner": i.assignee, "labels": i.labels.joined(separator: ", ")])
        }
        return db
    }

    public static func repoSlug(fromRemote url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://github.com/", "git@github.com:", "ssh://git@github.com/"] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s.split(separator: "/").count == 2 && !s.contains(":") ? s : nil
    }

    public static var ghInstalled: Bool { Shell.find("gh") != nil }
    public static func signedIn() async -> Bool {
        guard let r = try? await Shell.run("gh", ["auth", "status"], timeout: 15) else { return false }
        return r.ok
    }
    public static func signedInUser() async -> String? {
        guard let r = try? await Shell.run("gh", ["api", "user", "--jq", ".login"], timeout: 15), r.ok else { return nil }
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines); return s.isEmpty ? nil : s
    }

    public static func fetch(repo: String) async throws -> [Issue] {
        let out = try await Shell.check("gh", ["issue", "list", "--repo", repo, "--state", "all", "--limit", "200", "--json", "number,title,state,assignees,labels"], timeout: 45)
        return parse(Data(out.utf8))
    }

    /// Pushes a status change made in Antsly back to GitHub.
    public static func setState(repo: String, number: Int, open: Bool) async throws {
        _ = try await Shell.check("gh", ["issue", open ? "reopen" : "close", String(number), "--repo", repo], timeout: 30)
    }
    public static func create(repo: String, title: String) async throws {
        _ = try await Shell.check("gh", ["issue", "create", "--repo", repo, "--title", title, "--body", "Created from Antsly."], timeout: 30)
    }
    public static func comment(repo: String, number: Int, body: String) async throws {
        _ = try await Shell.check("gh", ["issue", "comment", String(number), "--repo", repo, "--body", body], timeout: 30)
    }
}
