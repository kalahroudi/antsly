// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One thing the app needs before it is useful: a tool, a runtime, a first-run resource.
/// The setup screen renders these as a checklist and does everything it can by itself.
/// Whatever it cannot do (admin password, a licence click, a system permission) becomes a manual step
/// with a copyable command, so nothing is ever left as "go read the README".
public struct Prereq: Identifiable, Equatable, Sendable {
    public enum Install: Equatable, Sendable {
        case brew(String)               // `brew install <formula>`, automated
        case cask(String)               // `brew install --cask <app>`, automated
        case command(String)            // runs in the user's terminal (needs a password or a TTY)
        case link(String)               // a download page; the user does it, then presses "check again"
        case none                       // nothing to install; only detected (e.g. a first-run resource)
    }
    public let id: String
    public let title: String
    public let detail: String           // why it is needed, in one plain sentence
    public let install: Install
    public var isMet: Bool
    /// Optional items belong to a feature (live collaboration, GitHub issues) and never block the app.
    public var optional: Bool

    public init(id: String, title: String, detail: String, install: Install, isMet: Bool, optional: Bool = false) {
        self.id = id; self.title = title; self.detail = detail; self.install = install; self.isMet = isMet; self.optional = optional
    }
}

public struct SetupState: Equatable, Sendable {
    public var items: [Prereq]
    public init(items: [Prereq]) { self.items = items }

    public static func gitPresent() -> Bool {
        ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func detect(workspace: URL = WorkspaceStore.defaultRoot) -> SetupState {
        let brew = Shell.find("brew") != nil
        var items: [Prereq] = [
            Prereq(id: "git", title: "Git", detail: "Keeps version history of your pages and shares them through GitHub.",
                   install: brew ? .brew("git") : .command("xcode-select --install"), isMet: gitPresent()),
            Prereq(id: "workspace", title: "Workspace folder", detail: "Where your pages live, as plain files you own.",
                   install: .none, isMet: FileManager.default.fileExists(atPath: workspace.appendingPathComponent("pages").path)),
            Prereq(id: "tailscale", title: "Tailscale", detail: "Lets people on your tailnet edit a workspace with you in real time.",
                   install: .cask("tailscale"), isMet: TailscaleStatus.appInstalled, optional: true),
            Prereq(id: "gh", title: "GitHub tool", detail: "Pulls your GitHub issues into a database and pushes changes back.",
                   install: .brew("gh"), isMet: GitHubIssues.ghInstalled, optional: true),
        ]
        let needsBrew = items.contains { if !$0.isMet { switch $0.install { case .brew, .cask: return true; default: return false } } else { return false } }
        if !brew, needsBrew {
            items.insert(Prereq(id: "brew", title: "Homebrew", detail: "Installs the tools below for you. It asks for your password once, so it runs in Terminal.",
                                install: .command(homebrewInstallCommand), isMet: false, optional: true), at: 0)
        }
        return SetupState(items: items)
    }

    public var missing: [Prereq] { items.filter { !$0.isMet } }
    public var missingRequired: [Prereq] { missing.filter { !$0.optional } }
    /// The app is usable once the required items are met. Optional features are offered in Settings.
    public var ready: Bool { missingRequired.isEmpty }
    public var brewFormulae: [String] { missing.compactMap { if case .brew(let f) = $0.install { f } else { nil } } }
    public var brewCasks: [String] { missing.compactMap { if case .cask(let f) = $0.install { f } else { nil } } }
    public var homebrewPresent: Bool { Shell.find("brew") != nil }
    /// Can the app install everything missing by itself?
    public var canAutoInstall: Bool {
        missing.allSatisfy { if case .brew = $0.install { homebrewPresent } else if case .cask = $0.install { homebrewPresent } else if case .none = $0.install { true } else { false } }
    }
    /// One line the user can paste into Terminal to do the automated part by hand.
    public var manualCommand: String {
        var parts: [String] = []
        if !brewFormulae.isEmpty { parts.append("brew install " + brewFormulae.joined(separator: " ")) }
        if !brewCasks.isEmpty { parts.append("brew install --cask " + brewCasks.joined(separator: " ")) }
        return parts.joined(separator: " && ")
    }

    /// The official Homebrew installer. It asks for a password, so it runs in a terminal, never silently.
    public static let homebrewInstallCommand = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

    /// Runs `brew install` for the missing formulae and streams its output.
    public static func installMissing(_ formulae: [String], casks: [String] = [], onLine: @escaping @Sendable (String) -> Void) async throws {
        let env = ["HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_ANALYTICS": "1"]
        if !formulae.isEmpty {
            let status = try await Shell.stream("brew", ["install"] + formulae, env: env, onLine: onLine)
            if status != 0 { throw ShellError.failed(command: "brew install", status: status, stderr: "brew install \(formulae.joined(separator: " ")) failed.") }
        }
        if !casks.isEmpty {
            let status = try await Shell.stream("brew", ["install", "--cask"] + casks, env: env, onLine: onLine)
            if status != 0 { throw ShellError.failed(command: "brew install --cask", status: status, stderr: "brew install --cask \(casks.joined(separator: " ")) failed.") }
        }
    }
}
