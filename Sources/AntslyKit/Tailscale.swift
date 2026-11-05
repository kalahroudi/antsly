// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What Antsly knows about Tailscale on this Mac, from `tailscale status --json`.
public struct TailscaleStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable { case notInstalled, stopped, needsLogin, running }
    public var state: State
    public var dnsName: String?        // this Mac, e.g. mo-mac.tail1a2b.ts.net
    public var ip: String?
    public var peers: [Peer]
    public struct Peer: Equatable, Sendable, Identifiable { public var id: String; public var name: String; public var ip: String; public var online: Bool; public var user: String }

    public static let notInstalled = TailscaleStatus(state: .notInstalled, dnsName: nil, ip: nil, peers: [])

    public static func parse(_ json: Data) -> TailscaleStatus {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return TailscaleStatus(state: .stopped, dnsName: nil, ip: nil, peers: []) }
        let backend = (o["BackendState"] as? String) ?? ""
        let state: State = switch backend { case "Running": .running; case "NeedsLogin", "NeedsMachineAuth": .needsLogin; default: .stopped }
        let me = o["Self"] as? [String: Any]
        var dns = (me?["DNSName"] as? String) ?? ""
        if dns.hasSuffix(".") { dns.removeLast() }
        let ip = (me?["TailscaleIPs"] as? [String])?.first(where: { !$0.contains(":") }) ?? (me?["TailscaleIPs"] as? [String])?.first
        let users = o["User"] as? [String: [String: Any]] ?? [:]
        let peers: [Peer] = (o["Peer"] as? [String: [String: Any]] ?? [:]).values.compactMap { p in
            guard let host = p["HostName"] as? String, let ips = p["TailscaleIPs"] as? [String], let first = ips.first(where: { !$0.contains(":") }) ?? ips.first else { return nil }
            let uid = (p["UserID"] as? Int).map(String.init) ?? ""
            let login = (users[uid]?["LoginName"] as? String) ?? ""
            return Peer(id: (p["ID"] as? String) ?? first, name: host, ip: first, online: (p["Online"] as? Bool) ?? false, user: login)
        }.sorted { $0.name < $1.name }
        return TailscaleStatus(state: state, dnsName: dns.isEmpty ? nil : dns, ip: ip, peers: peers)
    }

    /// Tailscale's CLI lives in different places depending on how it was installed.
    public static func cliPath() -> String? {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static var appInstalled: Bool { FileManager.default.fileExists(atPath: "/Applications/Tailscale.app") || cliPath() != nil }

    public static func current() async -> TailscaleStatus {
        guard let cli = cliPath() else { return .notInstalled }
        guard let r = try? await Shell.run(cli, ["status", "--json"], timeout: 8) else { return TailscaleStatus(state: .stopped, dnsName: nil, ip: nil, peers: []) }
        return parse(Data(r.stdout.utf8))
    }

    /// Who is behind a tailnet IP? Uses `tailscale whois`, so guests are identified by Tailscale, not by anything they claim.
    public static func whois(ip: String) async -> String? {
        guard let cli = cliPath(), let r = try? await Shell.run(cli, ["whois", "--json", ip], timeout: 8), r.ok,
              let o = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
              let up = o["UserProfile"] as? [String: Any] else { return nil }
        return up["LoginName"] as? String
    }
}

/// An invite is a link that names the host and the workspace. It carries no secret: the host still approves each person.
public struct Invite: Equatable, Sendable {
    public static let port: UInt16 = 47821
    public var host: String
    public var workspace: String
    public var url: String { "antsly://join/\(host)/\(workspace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workspace)" }
    public init(host: String, workspace: String) { self.host = host; self.workspace = workspace }
    public static func parse(_ s: String) -> Invite? {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme == "antsly", u.host == "join" else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 1, !parts[0].isEmpty else { return nil }
        return Invite(host: parts[0], workspace: parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : "Antsly")
    }
}

/// Only tailnet addresses (and this Mac itself) may connect to the collaboration port.
public enum TailnetAddress {
    public static func isAllowed(_ raw: String) -> Bool {
        let ip = raw.split(separator: "%").first.map(String.init) ?? raw
        if ip == "127.0.0.1" || ip == "::1" { return true }
        if ip.lowercased().hasPrefix("fd7a:115c:a1e0") { return true }
        let p = ip.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 100 && (64...127).contains(p[1])
    }
}
