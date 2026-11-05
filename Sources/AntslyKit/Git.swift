// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct Commit: Identifiable, Equatable, Sendable {
    public var id: String          // full hash
    public var subject: String
    public var author: String
    public var date: Date
    public var short: String { String(id.prefix(7)) }
}

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case context, added, removed, header }
    public var kind: Kind
    public var text: String
}

/// Version history and sharing through git. Pages are Markdown, so git's own merge works; conflicts are shown line by line.
public struct GitRepo: Sendable {
    public let dir: URL
    public init(dir: URL) { self.dir = dir }

    public var isRepo: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) }

    @discardableResult
    private func git(_ args: [String], timeout: TimeInterval = 60) async throws -> ShellResult {
        try await Shell.run("git", ["-c", "user.name=\(identity.name)", "-c", "user.email=\(identity.email)"] + args, cwd: dir, timeout: timeout)
    }

    /// Falls back to a neutral identity so commits never fail on a Mac with no git config.
    private var identity: (name: String, email: String) {
        func cfg(_ k: String) -> String? {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["config", "--global", k]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        return (cfg("user.name") ?? NSFullUserName(), cfg("user.email") ?? "\(NSUserName())@antsly.local")
    }

    public func initialize() async throws {
        guard !isRepo else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Shell.check("git", ["init", "-b", "main"], cwd: dir)
        try Data(".DS_Store\n.*.tmp\n".utf8).write(to: dir.appendingPathComponent(".gitignore"))
    }

    public func hasChanges() async -> Bool {
        guard let r = try? await git(["status", "--porcelain"]), r.ok else { return false }
        return !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Commits everything. Returns false when there was nothing to save.
    @discardableResult
    public func saveVersion(message: String) async throws -> Bool {
        guard await hasChanges() else { return false }
        _ = try await Shell.check("git", ["add", "-A"], cwd: dir)
        let r = try await git(["commit", "-m", message])
        guard r.ok else { throw ShellError.failed(command: "git commit", status: r.status, stderr: r.stderr + r.stdout) }
        return true
    }

    public func log(path: String? = nil, limit: Int = 50) async -> [Commit] {
        var args = ["log", "-\(limit)", "--pretty=format:%H%x1f%s%x1f%an%x1f%ct"]
        if let path { args += ["--", path] }
        guard let r = try? await git(args), r.ok else { return [] }
        return Self.parseLog(r.stdout)
    }

    public static func parseLog(_ s: String) -> [Commit] {
        s.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, let t = TimeInterval(f[3]) else { return nil }
            return Commit(id: f[0], subject: f[1], author: f[2], date: Date(timeIntervalSince1970: t))
        }
    }

    public func diff(of commit: Commit, path: String? = nil) async -> [DiffLine] {
        var args = ["show", "--pretty=format:", "--unified=2", commit.id]
        if let path { args += ["--", path] }
        guard let r = try? await git(args), r.ok else { return [] }
        return Self.parseDiff(r.stdout)
    }

    public static func parseDiff(_ s: String) -> [DiffLine] {
        s.components(separatedBy: "\n").compactMap { l in
            if l.hasPrefix("diff --git") || l.hasPrefix("index ") || l.hasPrefix("--- ") || l.hasPrefix("+++ ") || l.hasPrefix("new file") || l.hasPrefix("deleted file") { return nil }
            if l.hasPrefix("@@") { return DiffLine(kind: .header, text: l) }
            if l.hasPrefix("+") { return DiffLine(kind: .added, text: String(l.dropFirst())) }
            if l.hasPrefix("-") { return DiffLine(kind: .removed, text: String(l.dropFirst())) }
            if l.isEmpty { return nil }
            return DiffLine(kind: .context, text: String(l.dropFirst()))
        }
    }

    public func restore(_ commit: Commit, path: String) async throws {
        _ = try await Shell.check("git", ["checkout", commit.id, "--", path], cwd: dir)
    }

    // MARK: Remote sharing

    public var remoteURL: String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["remote", "get-url", "origin"]; p.currentDirectoryURL = dir
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    public func setRemote(_ url: String) async throws {
        if remoteURL == nil { _ = try await Shell.check("git", ["remote", "add", "origin", url], cwd: dir) }
        else { _ = try await Shell.check("git", ["remote", "set-url", "origin", url], cwd: dir) }
    }

    public enum SyncResult: Equatable, Sendable { case upToDate, pulled, pushed, conflicts([String]), offline }

    /// Pull (rebase), then push. Conflicting Markdown files are returned so the UI can offer "keep mine / keep theirs".
    public func sync() async throws -> SyncResult {
        guard remoteURL != nil else { return .upToDate }
        let pull = try await git(["pull", "--rebase", "--autostash", "origin", "main"], timeout: 90)
        if !pull.ok {
            let conflicts = await conflictedFiles()
            if !conflicts.isEmpty { return .conflicts(conflicts) }
            let text = (pull.stderr + pull.stdout).lowercased()
            if text.contains("could not resolve") || text.contains("unable to access") || text.contains("network") { return .offline }
            if text.contains("couldn't find remote ref") { /* empty remote: fall through to push */ } else {
                throw ShellError.failed(command: "git pull", status: pull.status, stderr: pull.stderr)
            }
        }
        let push = try await git(["push", "-u", "origin", "main"], timeout: 90)
        guard push.ok else {
            if push.stderr.lowercased().contains("could not resolve") { return .offline }
            throw ShellError.failed(command: "git push", status: push.status, stderr: push.stderr)
        }
        return pull.stdout.contains("Already up to date") || pull.stdout.isEmpty ? .pushed : .pulled
    }

    public func conflictedFiles() async -> [String] {
        guard let r = try? await git(["diff", "--name-only", "--diff-filter=U"]), r.ok else { return [] }
        return r.lines
    }

    /// Resolves one conflicted file by taking one side. During a rebase, "ours" is the remote and "theirs" is the local commit.
    public func resolve(_ file: String, keepMine: Bool) async throws {
        _ = try await Shell.check("git", ["checkout", keepMine ? "--theirs" : "--ours", "--", file], cwd: dir)
        _ = try await Shell.check("git", ["add", file], cwd: dir)
        let r = try await git(["-c", "core.editor=true", "rebase", "--continue"])
        if !r.ok, !(await conflictedFiles()).isEmpty { return }
    }
}
