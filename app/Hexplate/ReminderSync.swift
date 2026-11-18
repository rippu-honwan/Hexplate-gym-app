import Foundation
import HexplateCore
import UserNotifications

/// The workout-day reminder and the missed-workout nudge (HexplateCore Reminders) as local
/// notifications. The whole window is replaced whenever the profile or the day changes, so a
/// workout logged, a day noted or a plan edited takes its notification away (openGym syncReminder).
@MainActor
enum ReminderSync {
    private static var last: [Reminders.Note]?
    private static let ids = (0..<Reminders.reminderDays).map { "reminder-\(1000 + $0)" } + (0..<Reminders.nudgeDays).map { "reminder-\(2000 + $0)" }

    /// `ask`: the switch was just turned on, so the permission prompt may show.
    static func sync(_ model: AppModel, ask: Bool = false) {
        let notes = Reminders.notes(model.root, now: Date())
        guard ask || notes != last else { return }
        last = notes
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard !notes.isEmpty else { return }
        Task {
            var ok = await center.notificationSettings().authorizationStatus == .authorized
            if !ok && ask { ok = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
            guard ok else { last = nil; return }
            for n in notes {
                let label = n.names.isEmpty
                    ? (n.count == 1 ? String(localized: "1 routine") : String(localized: "\(n.count) routines"))
                    : n.names.joined(separator: " + ")
                let content = UNMutableNotificationContent()
                content.title = String(localized: String.LocalizationValue(n.title))
                content.body = String(localized: String.LocalizationValue(n.body)).replacingOccurrences(of: "{0}", with: label)
                content.sound = .default
                var when = DateComponents()
                let p = n.day.split(separator: "-").compactMap { Int($0) }
                (when.year, when.month, when.day, when.hour, when.minute) = (p[0], p[1], p[2], n.hour, n.minute)
                let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: "reminder-\(n.id)", content: content, trigger: trigger))
            }
        }
    }
}
