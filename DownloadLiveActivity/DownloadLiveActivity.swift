import ActivityKit
import SwiftUI
import WidgetKit

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Text(context.state.titleText)
                        .font(.headline)
                        .foregroundStyle(Color.black.opacity(0.88))
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundStyle(Color.black.opacity(0.88))
                }
                VStack(spacing: 7) {
                    stageRow("服务器解析", value: context.state.resolveProgress, color: .blue)
                    if context.attributes.kind != "音频 M4A" {
                        stageRow("下载视频", value: context.state.videoProgress, color: .indigo)
                    }
                    stageRow("下载 AAC", value: context.state.audioProgress, color: .cyan)
                }
                HStack {
                    Text(context.state.speedText)
                    Spacer()
                    Text(context.state.etaText)
                }
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.black.opacity(0.62))
            }
            .padding()
            .activityBackgroundTint(.white.opacity(0.96))
            .activitySystemActionForegroundColor(.blue)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.kind, systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.system(.headline, design: .monospaced))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.titleText)
                        .lineLimit(1)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 7) {
                        stageRow("服务器解析", value: context.state.resolveProgress, color: .blue)
                        if context.attributes.kind != "音频 M4A" {
                            stageRow("下载视频", value: context.state.videoProgress, color: .indigo)
                        }
                        stageRow("下载 AAC", value: context.state.audioProgress, color: .cyan)
                        HStack {
                            Text(context.state.speedText)
                            Spacer()
                            Text(context.state.etaText)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))%")
                    .font(.system(.caption2, design: .monospaced).bold())
            } minimal: {
                ZStack {
                    ProgressView(value: context.state.progress)
                        .progressViewStyle(.circular)
                        .tint(.blue)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .widgetURL(URL(string: "ytlocal://downloads"))
            .keylineTint(.blue)
        }
    }

    @ViewBuilder
    private func stageRow(_ title: String, value: Double, color: Color) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(min(max(value, 0), 1) * 100))%")
                    .monospacedDigit()
            }
            .font(.caption2.weight(.semibold))
            ProgressView(value: min(max(value, 0), 1))
                .tint(color)
        }
    }
}

@main
struct DownloadLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
    }
}
