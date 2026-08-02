import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = DownloadViewModel()
    @State private var shareItem: ShareItem?
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.91, green: 0.97, blue: 1.0),
                        Color(red: 0.83, green: 0.89, blue: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        header
                        composer
                        progressCard
                        filesCard
                    }
                    .padding(16)
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $shareItem) { item in
                ShareSheet(fileURL: item.fileURL)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(model: model)
            }
            .alert(model.alertTitle, isPresented: Binding(
                get: { model.errorText != nil },
                set: { if !$0 { model.cancelMessage() } }
            )) {
                Button("知道了", role: .cancel) { model.cancelMessage() }
            } message: {
                Text(model.errorText ?? "未知错误")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.blue.gradient)
                    .frame(width: 50, height: 50)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("本地下载器")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                Text("服务器解析 · 手机后台高速下载")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
        .padding(.top, 8)
    }

    private var composer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                TextField("粘贴 YouTube 或 Shorts 链接", text: $model.urlText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(2...4)
                    .padding(14)
                    .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button("粘贴") {
                    model.urlText = UIPasteboard.general.string ?? ""
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }

            Picker("类型", selection: $model.kind) {
                ForEach(DownloadKind.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if model.kind == .video {
                HStack {
                    Label("最高画质", systemImage: "sparkles.tv")
                    Spacer()
                    Picker("画质", selection: $model.quality) {
                        ForEach(VideoQuality.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(14)
                .background(.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Button(action: model.start) {
                HStack {
                    if model.isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.down.to.line.compact")
                    }
                    Text(model.isBusy ? "正在处理" : "开始下载")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 17))
            .disabled(model.isBusy || model.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .glassCard()
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("任务状态").font(.headline)
                Spacer()
                Text("\(Int(model.progress * 100))%")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.blue)
            }
            ProgressView(value: model.progress)
                .tint(.blue)
            Text(model.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                metric(title: "速度", value: model.speedText, icon: "speedometer")
                metric(title: "时间", value: model.etaText, icon: "clock")
            }
            Text(model.transferredText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)

            if let file = model.latestFile {
                Button {
                    shareItem = ShareItem(fileURL: file)
                } label: {
                    Label("再次分享或导出", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .glassCard()
    }

    private func metric(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本机文件").font(.headline)
                Spacer()
                Text("\(model.savedFiles.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.blue.opacity(0.12), in: Capsule())
            }

            if model.savedFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("暂无文件").font(.headline)
                    Text("完成的下载会出现在这里")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            } else {
                ForEach(model.savedFiles, id: \.self) { file in
                    HStack(spacing: 10) {
                        Image(systemName: file.pathExtension.lowercased() == "m4a" ? "waveform" : "film.fill")
                            .foregroundStyle(.blue)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.deletingPathExtension().lastPathComponent)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text(model.fileSizeText(file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { shareItem = ShareItem(fileURL: file) } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Button(role: .destructive) { model.delete(file) } label: {
                            Image(systemName: "trash")
                        }
                    }
                    .padding(.vertical, 7)
                    if file != model.savedFiles.last { Divider() }
                }
            }
        }
        .glassCard()
    }
}

private struct SettingsView: View {
    @ObservedObject var model: DownloadViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("下载") {
                    Toggle("允许蜂窝网络下载", isOn: $model.allowsCellular)
                    Toggle("下载完成通知", isOn: $model.notificationsEnabled)
                    Toggle("灵动岛与锁屏进度", isOn: $model.liveActivityEnabled)
                }

                Section {
                    TextField("解析接口", text: $model.serverURL, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("恢复默认接口") { model.resetServerURL() }
                } header: {
                    Text("解析服务器")
                } footer: {
                    Text("服务器负责 yt-dlp 解析和媒体中转；文件最终保存在本机。")
                }

                Section("关于") {
                    Link(destination: URL(string: "https://github.com/5488-ux/YouTubeNativeDownloader")!) {
                        Label("打开 GitHub", systemImage: "link")
                    }
                    LabeledContent("版本", value: appVersion)
                }

                Section("更新日志") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("2.2").font(.headline)
                        Text("• MOV 转换完成后自动保存到照片\n• 首次使用只请求一次照片写入权限\n• 不再强制打开手动保存弹窗\n• App 文件中仍保留原文件备份")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.2"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "8"
        return "\(version) (\(build))"
    }
}

private extension View {
    func glassCard() -> some View {
        padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .stroke(.white.opacity(0.75), lineWidth: 1)
            }
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let fileURL: URL
}

#Preview {
    ContentView()
}
