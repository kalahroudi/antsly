// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import Network
import AntslyKit

/// Live collaboration over Tailscale. The host listens on the tailnet port; guests connect to the host's MagicDNS name.
/// Only tailnet addresses are accepted, Tailscale itself says who is connecting, and the host approves each person once.
@MainActor @Observable
final class Collab {
    static let shared = Collab()

    struct Guest: Identifiable, Equatable { var id: String; var login: String; var name: String; var role: String?; var online: Bool }
    enum JoinState: Equatable { case idle, connecting, waiting, joined(String), denied(String), failed(String) }

    var hosting = false
    var guests: [Guest] = []
    var joinState: JoinState = .idle
    var joinedHost: String?
    /// pageID -> who is in it (name -> block they are in)
    var presence: [String: [String: String]] = [:]
    var status = TailscaleStatus.notInstalled

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var conns: [String: Conn] = [:]
    @ObservationIgnored private var upstream: Conn?
    private let defaults = UserDefaults.standard
    private var approvals: [String: String] {
        get { defaults.dictionary(forKey: "collabApprovals") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "collabApprovals") }
    }

    final class Conn: @unchecked Sendable {
        let c: NWConnection; var buf = LineBuffer(); let id = UUID().uuidString
        var login = "", name = "", role: String?, ip = ""
        init(_ c: NWConnection) { self.c = c }
        func send(_ m: CollabMessage) { c.send(content: m.encoded() + Data("\n".utf8), completion: .contentProcessed { _ in }) }
    }

    func refreshStatus() async { status = await TailscaleStatus.current() }
    var invite: Invite? { status.dnsName.map { Invite(host: $0, workspace: "Antsly") } }

    // MARK: Hosting

    func startHosting() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Invite.port)!)
            l.newConnectionHandler = { [weak self] c in MainActor.assumeIsolated { self?.accept(c) } }
            l.stateUpdateHandler = { [weak self] st in MainActor.assumeIsolated {
                if case .failed(let e) = st { AppLog.error(e, context: "collab listener"); self?.hosting = false; self?.listener = nil } } }
            l.start(queue: .main); listener = l; hosting = true
        } catch { AppLog.error(error, context: "collab listener"); AppModel.shared.show("Could not start sharing. Another app may be using the sharing port.", error: true) }
    }

    func stopHosting() {
        listener?.cancel(); listener = nil; hosting = false
        conns.values.forEach { $0.c.cancel() }; conns = [:]; guests = []
    }

    private func accept(_ c: NWConnection) {
        var ip = ""
        if case .hostPort(let h, _) = c.endpoint { ip = "\(h)" }
        guard TailnetAddress.isAllowed(ip) else { c.cancel(); return }       // never talk to anything outside the tailnet
        let conn = Conn(c); conn.ip = ip; conns[conn.id] = conn
        c.stateUpdateHandler = { [weak self, weak conn] st in MainActor.assumeIsolated {
            if case .cancelled = st, let conn { self?.dropGuest(conn) }
            if case .failed = st, let conn { self?.dropGuest(conn) } } }
        c.start(queue: .main)
        read(conn) { [weak self] m in self?.hostReceived(m, from: conn) }
    }

    private func dropGuest(_ conn: Conn) {
        conns[conn.id] = nil
        if let i = guests.firstIndex(where: { $0.id == conn.id }) { guests[i].online = false; if guests[i].role == nil { guests.remove(at: i) } }
    }

    private func read(_ conn: Conn, _ handle: @escaping (CollabMessage) -> Void) {
        conn.c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self, weak conn] data, _, done, err in
            MainActor.assumeIsolated {
                guard let self, let conn else { return }
                if let data { for line in conn.buf.feed(data) { if let m = CollabMessage.decode(line) { handle(m) } } }
                if done || err != nil { conn.c.cancel(); return }
                self.read(conn, handle)
            }
        }
    }

    private func hostReceived(_ m: CollabMessage, from conn: Conn) {
        switch m {
        case .hello(let name, _):
            conn.name = name
            Task { @MainActor in
                let login = conn.ip == "127.0.0.1" || conn.ip == "::1" ? "this-mac" : (await TailscaleStatus.whois(ip: conn.ip) ?? "unknown-\(conn.ip)")
                conn.login = login
                let role = approvals[login]
                guests.removeAll { $0.login == login }
                guests.append(Guest(id: conn.id, login: login, name: name, role: role, online: true))
                if let role { welcome(conn, role: role) } else { conn.send(.denied(reason: "Waiting for the host to approve you.")) }
            }
        case .page(let p):
            guard conn.role == "edit" else { return }
            WorkspaceModel.shared.mergeRemote(p)
            relay(.page(p), except: conn)
        case .removed(let id):
            guard conn.role == "edit" else { return }
            WorkspaceModel.shared.removeRemote(pageID: id); relay(m, except: conn)
        case .presence(let pid, let name, let block):
            apply(presence: pid, name: name, block: block); relay(m, except: conn)
        default: break
        }
    }

    private func welcome(_ conn: Conn, role: String) {
        conn.role = role
        conn.send(.approved(role: role))
        let pages = WorkspaceModel.shared.pages
        conn.send(.pageList(pages.map { .init(id: $0.id, title: $0.title) }))
        for p in pages { conn.send(.page(p)) }
    }

    func approve(_ guestID: String, role: String) {
        guard let i = guests.firstIndex(where: { $0.id == guestID }) else { return }
        guests[i].role = role; approvals[guests[i].login] = role
        if let c = conns[guestID] { welcome(c, role: role) }
    }

    func revoke(_ guestID: String) {
        guard let g = guests.first(where: { $0.id == guestID }) else { return }
        approvals[g.login] = nil; conns[guestID]?.c.cancel(); guests.removeAll { $0.id == guestID }
    }

    private func relay(_ m: CollabMessage, except: Conn? = nil) { for c in conns.values where c.role != nil && c !== except { c.send(m) } }

    // MARK: Joining

    func join(_ invite: Invite) {
        leave()
        joinState = .connecting; joinedHost = invite.host
        let c = NWConnection(host: NWEndpoint.Host(invite.host), port: NWEndpoint.Port(rawValue: Invite.port)!, using: .tcp)
        let conn = Conn(c); upstream = conn
        c.stateUpdateHandler = { [weak self] st in MainActor.assumeIsolated {
            switch st {
            case .ready: conn.send(.hello(name: Prefs.shared.displayName, device: Host.current().localizedName ?? "Mac"))
            case .failed, .waiting: self?.joinState = .failed("Could not reach \(invite.host). Check that Tailscale is on and the host has Antsly open.")
            default: break
            } } }
        c.start(queue: .main)
        read(conn) { [weak self] m in self?.guestReceived(m) }
    }

    func leave() { upstream?.c.cancel(); upstream = nil; joinState = .idle; joinedHost = nil }

    private func guestReceived(_ m: CollabMessage) {
        switch m {
        case .approved(let role): joinState = .joined(role)
        case .denied(let why): joinState = why.hasPrefix("Waiting") ? .waiting : .denied(why)
        case .page(let p): WorkspaceModel.shared.mergeRemote(p)
        case .removed(let id): WorkspaceModel.shared.removeRemote(pageID: id)
        case .presence(let pid, let name, let block): apply(presence: pid, name: name, block: block)
        default: break
        }
    }

    // MARK: Sending local edits

    func send(_ page: Page) {
        if hosting { relay(.page(page)) }
        if case .joined("edit") = joinState { upstream?.send(.page(page)) }
    }
    func sendRemoved(_ id: String) {
        if hosting { relay(.removed(pageID: id)) }
        if case .joined("edit") = joinState { upstream?.send(.removed(pageID: id)) }
    }
    func sendPresence(pageID: String, blockID: String?) {
        let name = Prefs.shared.displayName
        let m = CollabMessage.presence(pageID: pageID, name: name, blockID: blockID)
        if hosting { relay(m) }
        if case .joined = joinState { upstream?.send(m) }
    }
    private func apply(presence pid: String, name: String, block: String?) {
        if let block { presence[pid, default: [:]][name] = block } else { presence[pid]?[name] = nil }
    }

    var peopleOnline: Int { guests.filter(\.online).count + (joinedHost != nil && joinState != .idle ? 1 : 0) }
}
