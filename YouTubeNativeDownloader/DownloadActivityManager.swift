import ActivityKit
import Foundation

@MainActor
final class DownloadActivityManager {
    static let shared = DownloadActivityManager()
    private var activity: Activity<DownloadActivityAttributes>?

    private init() {}

    func start(title: String, kind: String, enabled: Bool) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let staleActivities = Activity<DownloadActivityAttributes>.activities
        let attributes = DownloadActivityAttributes(title: title, kind: kind)
        let state = DownloadActivityAttributes.ContentState(
            progress: 0,
            resolveProgress: 0.04,
            videoProgress: 0,
            audioProgress: 0,
            speedText: "准备中",
            etaText: "--",
            statusText: "服务器正在解析",
            titleText: title
        )
        do {
            if #available(iOS 16.2, *) {
                let newActivity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
                activity = newActivity
                Task {
                    for staleActivity in staleActivities where staleActivity.id != newActivity.id {
                        await staleActivity.end(
                            ActivityContent(state: state, staleDate: nil),
                            dismissalPolicy: .immediate
                        )
                    }
                }
            }
        } catch {
            activity = nil
            DiagnosticLogger.shared.error(error, stage: "创建灵动岛实时活动")
        }
    }

    func update(
        progress: Double,
        resolveProgress: Double,
        videoProgress: Double,
        audioProgress: Double,
        speedText: String,
        etaText: String,
        statusText: String,
        titleText: String
    ) {
        guard let activity else { return }
        let state = DownloadActivityAttributes.ContentState(
            progress: progress,
            resolveProgress: resolveProgress,
            videoProgress: videoProgress,
            audioProgress: audioProgress,
            speedText: speedText,
            etaText: etaText,
            statusText: statusText,
            titleText: titleText
        )
        Task {
            if #available(iOS 16.2, *) {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    func end(finalStatus: String) {
        let currentActivity = activity
        self.activity = nil
        let state = DownloadActivityAttributes.ContentState(
            progress: finalStatus == "下载完成" ? 1 : 0,
            resolveProgress: finalStatus == "下载完成" ? 1 : 0,
            videoProgress: finalStatus == "下载完成" ? 1 : 0,
            audioProgress: finalStatus == "下载完成" ? 1 : 0,
            speedText: "",
            etaText: "",
            statusText: finalStatus,
            titleText: currentActivity?.attributes.title ?? "YouTube 下载任务"
        )
        var activities = Activity<DownloadActivityAttributes>.activities
        if let currentActivity,
           !activities.contains(where: { $0.id == currentActivity.id }) {
            activities.append(currentActivity)
        }
        Task {
            if #available(iOS 16.2, *) {
                for activity in activities {
                    await activity.end(
                        ActivityContent(state: state, staleDate: nil),
                        dismissalPolicy: .immediate
                    )
                }
            }
        }
    }

    func dismissAll() {
        activity = nil
        let activities = Activity<DownloadActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        let state = DownloadActivityAttributes.ContentState(
            progress: 0,
            resolveProgress: 0,
            videoProgress: 0,
            audioProgress: 0,
            speedText: "",
            etaText: "",
            statusText: "已结束",
            titleText: "YouTube 下载任务"
        )
        Task {
            if #available(iOS 16.2, *) {
                for activity in activities {
                    await activity.end(
                        ActivityContent(state: state, staleDate: nil),
                        dismissalPolicy: .immediate
                    )
                }
            }
        }
    }
}
