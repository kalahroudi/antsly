// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AntslyKit

/// Sharing: live collaboration over Tailscale, and version history, sharing and issues through git.
struct SharingPane: View {
    @State private var tab: Tab = .live
    enum Tab: Hashable { case live, git }
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Sharing") { EmptyView() } tabs: { TabBar(tabs: [(Tab.live, "Live collaboration"), (Tab.git, "Git and issues")], selection: $tab) }
            StyledScroll {
                Group { if tab == .live { LiveView() } else { GitView() } }.padding(22).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct LiveView: View {
    let collab = Collab.shared
    let prefs = Prefs.shared
    let model = AppModel.shared
    @State private var inviteText = ""

    var body: some View {
        @Bindable var p = prefs
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Tailscale") {
                SettingRow("Tailscale", tsDetail) { tsAction }
            }
            if collab.status.state == .running {
                SettingsGroup("Share this workspace") {
                    SettingRow("Let people on my tailnet edit with me", "People join with a link and you approve each person once. Nothing is exposed to the internet.") {
                        Toggle("", isOn: Binding(get: { prefs.liveCollab }, set: { prefs.liveCollab = $0; if $0 { collab.startHosting() } else { collab.stopHosting() } })).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                    }
                    SettingRow("Your name", "Shown next to your cursor and in the guest list.") { TextField("Name", text: $p.displayName).textFieldStyle(.roundedBorder).frame(width: 180) }
                }
                if prefs.liveCollab { hostSection }
                joinSection
            }
        }
        .task { await collab.refreshStatus(); if prefs.liveCollab { collab.startHosting() } }
    }

    private var tsDetail: String {
        switch collab.status.state {
        case .notInstalled: "Not installed. Antsly can install it for you."
        case .stopped: "Installed but not connected."
        case .needsLogin: "Installed. Sign in once to join your tailnet."
        case .running: "Connected as \(collab.status.dnsName ?? "this Mac")."
        }
    }

    @ViewBuilder private var tsAction: some View {
        switch collab.status.state {
        case .notInstalled:
            Button { model.install(id: "tailscale") } label: { HStack(spacing: 6) { if model.busy { ProgressView().controlSize(.small) }; Text("Install Tailscale") } }.buttonStyle(Pill(kind: .primary)).disabled(model.busy)
        case .stopped, .needsLogin:
            HStack { Button("Open Tailscale") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app")) }.buttonStyle(Pill(kind: .primary)); Button("Check again") { Task { await collab.refreshStatus() } }.buttonStyle(Pill()) }
        case .running: Badge(text: "ready", kind: .ok)
        }
    }

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let inv = collab.invite {
                SettingsGroup("Invite") {
                    SettingRow("Invite link", "Send this to people on your tailnet. Someone outside it needs a Tailscale invite or node share first.") {
                        HStack { Text(inv.url).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220); CopyButton(text: inv.url, label: "Copy invite link") }
                    }
                }
            }
            SettingsGroup("People") {
                if collab.guests.isEmpty { SettingRow("Nobody has joined yet", "People who open your invite appear here for approval.") { EmptyView() } }
                ForEach(collab.guests) { g in
                    SettingRow(g.name, "\(g.login)\(g.online ? "" : " · offline")") {
                        if let role = g.role {
                            HStack {
                                Menu(role == "edit" ? "Can edit" : "Can view") {
                                    Button("Can edit") { collab.approve(g.id, role: "edit") }; Button("Can view") { collab.approve(g.id, role: "view") }
                                    Divider(); Button("Remove", role: .destructive) { collab.revoke(g.id) }
                                }.menuStyle(.borderlessButton).fixedSize()
                            }
                        } else {
                            HStack { Button("Approve to edit") { collab.approve(g.id, role: "edit") }.buttonStyle(Pill(kind: .primary)); Button("View only") { collab.approve(g.id, role: "view") }.buttonStyle(Pill()) }
                        }
                    }
                }
            }
        }
    }

    private var joinSection: some View {
        SettingsGroup("Join someone else's workspace") {
            SettingRow("Invite link", joinDetail) {
                HStack {
                    TextField("antsly://join/…", text: $inviteText).textFieldStyle(.roundedBorder).frame(width: 220)
                    if collab.joinState == .idle || { if case .failed = collab.joinState { true } else { false } }() || { if case .denied = collab.joinState { true } else { false } }() {
                        Button("Join") { if let i = Invite.parse(inviteText) { collab.join(i) } else { model.show("That does not look like an Antsly invite link.", error: true) } }.buttonStyle(Pill(kind: .primary)).disabled(inviteText.isEmpty)
                    } else { Button("Leave") { collab.leave() }.buttonStyle(Pill()) }
                }
            }
        }
    }
    private var joinDetail: String {
        switch collab.joinState {
        case .idle: "Paste a link from the host. Their pages are merged into your workspace."
        case .connecting: "Connecting…"
        case .waiting: "Waiting for the host to approve you."
        case .joined(let r): "Connected to \(collab.joinedHost ?? "the host") as \(r == "edit" ? "an editor" : "a viewer")."
        case .denied(let w): w
        case .failed(let w): w
        }
    }
}

struct GitView: View {
    let ws = WorkspaceModel.shared
    let prefs = Prefs.shared
    let model = AppModel.shared
    @State private var remoteText = ""
    @State private var ghIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Version history") {
                SettingRow("Keep a history of changes", "Saves a version about every five minutes while Antsly is open. Restore any page from its History tab.") {
                    Toggle("", isOn: Binding(get: { prefs.historyEnabled && ws.repo.isRepo }, set: { on in prefs.historyEnabled = on; if on { Task { await ws.enableHistory() } } })).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
            }
            if ws.repo.isRepo {
                SettingsGroup("Share through git") {
                    if let r = ws.remote ?? ws.repo.remoteURL {
                        SettingRow("Repository", r) { Button { Task { await ws.saveVersion(manual: true) } } label: { HStack(spacing: 6) { if ws.gitBusy { ProgressView().controlSize(.small) }; Text("Sync now") } }.buttonStyle(Pill(kind: .primary)).disabled(ws.gitBusy) }
                        SettingRow("Sync automatically", "Pulls and pushes whenever a version is saved.") { Toggle("", isOn: Bindable(prefs).autoSyncGit).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }
                        if !ws.gitNote.isEmpty { SettingRow("Last result", ws.gitNote) { EmptyView() } }
                    } else {
                        SettingRow("Create a private repository on GitHub", ghIn ? "Uses your GitHub sign-in. Your pages are uploaded to a private repository." : "Sign in to GitHub first. It takes one command, shown below.") {
                            Button { Task { await ws.createGitHubRepo() } } label: { Text("Create repository") }.buttonStyle(Pill(kind: .primary)).disabled(!ghIn || ws.gitBusy)
                        }
                        SettingRow("Or connect an existing repository", "Paste its address.") {
                            HStack { TextField("https://github.com/you/notes.git", text: $remoteText).textFieldStyle(.roundedBorder).frame(width: 240); Button("Connect") { Task { await ws.connect(remoteURL: remoteText) } }.buttonStyle(Pill()).disabled(remoteText.isEmpty) }
                        }
                    }
                }
                SettingsGroup("GitHub issues") {
                    SettingRow("Pull issues into a database", "Issues become rows. Closing or reopening one here updates GitHub.") {
                        Button { Task { await ws.syncIssues() } } label: { Text("Sync issues") }.buttonStyle(Pill(kind: .primary)).disabled(!ghIn || (ws.remote ?? ws.repo.remoteURL) == nil)
                    }
                }
            }
            if !ghIn { ghSetup }
        }
        .task { await ws.refreshHistory(); await refreshGH() }
    }

    private var ghSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub needs you once").font(.system(size: 13, weight: .semibold))
            if !GitHubIssues.ghInstalled {
                Text("Antsly installs the GitHub tool, then you sign in through your browser.").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Install the GitHub tool") { model.install(id: "gh") }.buttonStyle(Pill(kind: .primary)).disabled(model.busy)
            } else {
                Text("Run this in Terminal and follow the browser prompt. Antsly never sees your password.").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack { Text("gh auth login --web --git-protocol https").font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled); CopyButton(text: "gh auth login --web --git-protocol https", label: "Copy command") }
                HStack { Button("Open Terminal") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")) }.buttonStyle(Pill()); Button("I did it, check again") { Task { await refreshGH() } }.buttonStyle(Pill()) }
            }
        }.card()
    }
    private func refreshGH() async { ghIn = GitHubIssues.ghInstalled ? await GitHubIssues.signedIn() : false }
}
