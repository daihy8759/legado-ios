import Foundation
import UserNotifications
import BackgroundTasks
import UIKit

/// 章节更新提醒。纯本地通知，不经过任何服务器。
@MainActor
final class ChapterUpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ChapterUpdateNotifier()

    private static let enabledKey = "chapterUpdateNotifications"
    private let center = UNUserNotificationCenter.current()
    static let backgroundTaskID = "org.legado.ios.chapter-refresh"

    private override init() {
        super.init()
        center.delegate = self
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// 开启时需要系统授权；被拒绝时返回 false，调用方应回滚开关状态。
    func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            center.removePendingNotificationRequests(withIdentifiers: ["chapter-update"])
            center.removeDeliveredNotifications(withIdentifiers: ["chapter-update"])
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskID)
            if #available(iOS 16.0, *) { try? await center.setBadgeCount(0) }
            else { UIApplication.shared.applicationIconBadgeNumber = 0 }
            return true
        }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return false }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        scheduleBackgroundRefresh()
        return true
    }

    func notify(updates: [(bookName: String, added: Int)], unreadCount: Int) {
        guard isEnabled else { return }
        let total = updates.reduce(0) { $0 + $1.added }
        guard total > 0 else { return }

        let content = UNMutableNotificationContent()
        content.badge = NSNumber(value: max(unreadCount, 0))
        content.title = "书架有新章节"
        content.sound = .default
        if updates.count == 1, let first = updates.first {
            content.body = "《\(first.bookName)》更新了 \(first.added) 章"
        } else {
            let names = updates.prefix(3).map { "《\($0.bookName)》" }.joined(separator: "、")
            content.body = "\(names)等 \(updates.count) 本书共更新 \(total) 章"
        }
        content.userInfo = ["deepLink": "legado://bookshelf"]
        let defaults = UserDefaults.standard
        let policy = ChapterNotificationSchedule(quietHoursEnabled: defaults.bool(forKey: "chapterQuietHours"),
                                                startHour: defaults.object(forKey: "chapterQuietStart") as? Int ?? 22,
                                                endHour: defaults.object(forKey: "chapterQuietEnd") as? Int ?? 8)
        let date = policy.deliveryDate(after: Date())
        let trigger = date.map {
            UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0), repeats: false)
        }
        let request = UNNotificationRequest(
            identifier: "chapter-update",
            content: content,
            trigger: trigger
        )
        center.add(request)
        updateBadge(unreadCount)
    }

    func updateBadge(_ count: Int) {
        guard isEnabled else { return }
        if #available(iOS 16.0, *) {
            Task { try? await center.setBadgeCount(max(count, 0)) }
        } else { UIApplication.shared.applicationIconBadgeNumber = max(count, 0) }
        if count == 0 {
            center.removePendingNotificationRequests(withIdentifiers: ["chapter-update"])
            center.removeDeliveredNotifications(withIdentifiers: ["chapter-update"])
        }
    }

    func scheduleBackgroundRefresh() {
        guard isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3_600)
        try? BGTaskScheduler.shared.submit(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            NotificationCenter.default.post(name: Notification.Name("legado.openBookshelf"), object: nil)
        }
    }
}
