import Foundation
import UserNotifications
import AppKit

/// Wraps UNUserNotificationCenter. Retained delegate opens the run URL on click
/// and shows banners while the app is foreground.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    /// Set the delegate BEFORE requesting authorization.
    func setup() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String, url: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["url": url]
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    // Click → open the run in the browser.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlStr = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlStr) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }

    // Show even when the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
