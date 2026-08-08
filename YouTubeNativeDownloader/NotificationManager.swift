import Foundation
import UserNotifications

private final class DownloadNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

enum NotificationManager {
    private static let delegate = DownloadNotificationDelegate()

    static func configure() {
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func requestAuthorization() {
        configure()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                DiagnosticLogger.shared.error(error, stage: "请求下载通知权限")
            } else {
                DiagnosticLogger.shared.info("下载通知权限请求完成; granted=\(granted)")
            }
        }
    }

    static func post(title: String, body: String, enabled: Bool) {
        guard enabled else {
            DiagnosticLogger.shared.info("下载通知已在设置中关闭")
            return
        }

        configure()
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                enqueue(center: center, title: title, body: body)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        DiagnosticLogger.shared.error(error, stage: "下载完成时请求通知权限")
                    } else if granted {
                        enqueue(center: center, title: title, body: body)
                    } else {
                        DiagnosticLogger.shared.warning("用户未允许下载完成通知")
                    }
                }
            case .denied:
                DiagnosticLogger.shared.warning("下载通知权限已被系统拒绝，请到 iPhone 设置中开启")
            @unknown default:
                DiagnosticLogger.shared.warning("无法识别当前通知授权状态")
            }
        }
    }

    private static func enqueue(
        center: UNUserNotificationCenter,
        title: String,
        body: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "youtube-downloads"

        let request = UNNotificationRequest(
            identifier: "download-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                DiagnosticLogger.shared.error(error, stage: "投递下载通知")
            } else {
                DiagnosticLogger.shared.info("下载通知已提交; title=\(title)")
            }
        }
    }
}
