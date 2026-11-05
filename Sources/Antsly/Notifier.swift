// SPDX-License-Identifier: Apache-2.0

import Foundation
import UserNotifications
import AntslyKit

/// Hands reminders to macOS, which delivers them on time even when Antsly is closed.
/// Only works from the installed app: a bare binary has no bundle for the system to attach notifications to.
@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }
    private static let limit = 60          // macOS keeps at most 64 pending notifications per app

    /// Replaces everything pending with the open reminders that are still ahead. Cheap, so call it after any change.
    func sync(_ reminders: [Reminder], now: Date = Date()) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }   // asks once; the system remembers the answer
        center.removeAllPendingNotificationRequests()

        var requests: [(date: Date, request: UNNotificationRequest)] = []
        for r in reminders where !r.done {
            if r.when > now { requests.append((r.when, make(id: r.id, title: r.title, body: "Reminder", at: r.when))) }
            let again = r.when.addingTimeInterval(2 * 3600)
            if r.nudge, again > now { requests.append((again, make(id: r.id + "-nudge", title: r.title, body: "Still open", at: again))) }
        }
        for (_, req) in requests.sorted(by: { $0.date < $1.date }).prefix(Self.limit) { center.add(req) }
    }

    private func make(id: String, title: String, body: String, at date: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
