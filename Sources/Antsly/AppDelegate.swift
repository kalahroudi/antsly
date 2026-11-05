// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import AntslyKit

/// Owns the menu bar item (with its popover arrow), the Dock presence, and the Manager window.
/// The popover's views and the window are created on demand and destroyed on close, so a closed UI holds no view memory.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var managerWindow: NSWindow?
    private let model = AppModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SnapshotMode.dir != nil { SnapshotMode.run(); return }
        WorkspaceModel.shared.load()
        if Prefs.shared.liveCollab { Collab.shared.startHosting(); Task { await Collab.shared.refreshStatus() } }
        installMouseButtons()
        Prefs.shared.applyTheme()
        Prefs.shared.applyDockIcon()
        NSApp.applicationIconImage = AppIcon.image(size: 512, padded: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.image(.idle)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.setAccessibilityLabel("Antsly")

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        model.onStatusChange = { [weak self] state in self?.statusItem.button?.image = StatusIcon.image(state) }

        Task { await model.refresh() }
        Updater.shared.confirmLaunch()                                   // tells a pending swap script "the new version started"
        Task { Updater.shared.autoCheckIfDue(enabled: Prefs.shared.autoCheckUpdates) }
        if model.needsSetup { showManager() }                            // first run: show the guided setup, not an empty window
    }

    /// The popover does not follow NSApp.appearance on its own (it takes the menu bar's look), so set it explicitly.
    func applyAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    @objc func openSettings() { showManager(pane: .settings) }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: "Open Antsly", action: #selector(openManager), keyEquivalent: "").target = self
            m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Quit Antsly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = m; statusItem.button?.performClick(nil); statusItem.menu = nil   // menu only for this click
        } else { togglePopover() }
    }
    @objc private func openManager() { showManager() }

    private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        applyAppearance()
        let host = NSHostingController(rootView: PopoverView(openManager: { [weak self] p in self?.showManager(pane: p) }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil   // release the popover's views while hidden
    }

    func showManager(pane: Pane? = nil) {
        if let pane { Nav.shared.pane = pane }
        popover.performClose(nil)
        if managerWindow == nil {
            // Open large enough that panes need no scrolling, but never larger than the screen.
            let vis = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let size = NSSize(width: min(1240, vis.width * 0.92), height: min(800, vis.height * 0.92))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 900, height: 620)
            w.setFrameAutosaveName("AntslyManager2")
            w.delegate = self
            w.contentView = NSHostingView(rootView: ManagerView())
            if !w.setFrameUsingName("AntslyManager2") { w.center() }
            managerWindow = w
        }
        managerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.setManagerVisible(true)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === managerWindow else { return }
        model.setManagerVisible(false)
        WorkspaceModel.shared.flush()   // saved first, then the window's views are dropped
        managerWindow?.contentView = nil   // frees the SwiftUI tree
        managerWindow = nil
    }

    // Clicking the Dock icon opens the Manager.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showManager(); return true
    }

    // The app lives in the menu bar: closing the last window must not quit it.
    func applicationDidResignActive(_ notification: Notification) { WorkspaceModel.shared.flush() }
    func applicationWillTerminate(_ notification: Notification) { WorkspaceModel.shared.flush(); Collab.shared.stopHosting() }
    // MARK: Undo, redo, back, forward

    @objc func undoAction() { WorkspaceModel.shared.undo() }
    @objc func redoAction() { WorkspaceModel.shared.redo() }
    @objc func goBack() { Nav.shared.back() }
    @objc func goForward() { Nav.shared.forward() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undoAction): return WorkspaceModel.shared.canUndo
        case #selector(redoAction): return WorkspaceModel.shared.canRedo
        case #selector(goBack): return Nav.shared.canGoBack
        case #selector(goForward): return Nav.shared.canGoForward
        default: return true
        }
    }

    /// Side buttons on a mouse: button 4 is back, button 5 is forward. Only acts while the Manager window is in front.
    private func installMouseButtons() {
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] e in
            guard let self, e.window === self.managerWindow else { return e }
            switch e.buttonNumber {
            case 3: Nav.shared.back(); return nil
            case 4: Nav.shared.forward(); return nil
            default: return e
            }
        }
    }

    @objc func newPage() { showManager(pane: .workspace); WorkspaceModel.shared.newPage() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
