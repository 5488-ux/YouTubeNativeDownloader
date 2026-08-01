import ActivityKit
import Foundation

@MainActor
final class DownloadActivityManager {
    static let shared = DownloadActivityManager()
    private var activity: Activity<DownloadActivityAttributes>?

    private init() {}

    func start(title: String, kind: String, enabled: Bool) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end(finalStatus: "已结束")
        let attributes = DownloadActivityAttributes(title: title, kind: kind)
        let state = DownloadActivityAttributes.ContentState(
            progress: 0,
            speedText: "准备中",
            etaText: "--",
            statusText: "正在解析"
        )
        do {
            if #available(iOS 16.2, *) {
                activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
            }
        } catch {
            activity = nil
        }
    }

    func update(progress: Double, speedText: String, etaText: String, statusText: String) {
        guard let activity else { return }
        let state = DownloadActivityAttributes.ContentState(
            progress: progress,
            speedText: speedText,
            etaText: etaText,
            statusText: statusText
        )
        Task {
            if #available(iOS 16.2, *) {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    func end(finalStatus: String) {
        guard let activity else { return }
        self.activity = nil
        let state = DownloadActivityAttributes.ContentState(
            progress: finalStatus == "下载完成" ? 1 : 0,
            speedText: "",
            etaText: "",
            statusText: finalStatus
        )
        Task {
            if #available(iOS 16.2, *) {
                await activity.end(
                    ActivityContent(state: state, staleDate: nil),
                    dismissalPolicy: .default
                )
            }
        }
    }
}
