import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = DownloadViewModel()
    @StateObject private var ffmpeg = FFmpegComponentManager.shared
    @State private var shareItem: ShareItem?
    @State private var showingSettings = false
    @State private var showingFFmpegPrompt = false
    @State private var showingWhatsNew = false
    @AppStorage("lastPresentedChangelogVersion") private var lastPresentedChangelogVersion = ""

    var body: some View {
        NavigationStack {
            ZStack {
                appBackground

                ScrollView {
                    VStack(spacing: 16) {
                        header
                        composer
                        if ffmpeg.state == .downloading || ffmpeg.state == .verifying {
                            ffmpegDownloadCard
                        }
                        progressCard
                        filesCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 36)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationBarHidden(true)
            .sheet(item: $shareItem) { item in
                ShareSheet(fileURL: item.fileURL)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(model: model, ffmpeg: ffmpeg)
            }
            .sheet(isPresented: $showingWhatsNew, onDismiss: scheduleFFmpegPrompt) {
                WhatsNewView(release: ReleaseNote.current) {
                    lastPresentedChangelogVersion = ReleaseNote.current.version
                    showingWhatsNew = false
                }
                .interactiveDismissDisabled()
            }
            .onAppear {
                guard !showingWhatsNew, !showingFFmpegPrompt else { return }
                if lastPresentedChangelogVersion != ReleaseNote.current.version {
                    showingWhatsNew = true
                } else {
                    scheduleFFmpegPrompt()
                }
            }
            .alert("下载完整 FFmpeg 组件", isPresented: $showingFFmpegPrompt) {
                Button("下载完整包") {
                    ffmpeg.install(allowsCellular: model.allowsCellular)
                }
                Button("暂不下载", role: .cancel) {}
            } message: {
                Text("高清视频需要在 iPhone 本机合并。标准 WASI 完整组件约 17.1 MB，只下载一次，可在设置中更新或删除。")
            }
            .alert(model.alertTitle, isPresented: Binding(
                get: { model.errorText != nil },
                set: { if !$0 { model.cancelMessage() } }
            )) {
                if model.alertTitle == "需要合并组件" {
                    Button("下载完整包") {
                        model.cancelMessage()
                        ffmpeg.install(allowsCellular: model.allowsCellular)
                    }
                }
                Button("知道了", role: .cancel) { model.cancelMessage() }
                Button("复制详细日志") {
                    UIPasteboard.general.string = DiagnosticLogger.shared.text()
                    model.cancelMessage()
                }
            } message: {
                Text(model.errorText ?? "未知错误")
            }
        }
        .preferredColorScheme(.light)
    }

    private func scheduleFFmpegPrompt() {
        guard !ffmpeg.isInstalled, !showingWhatsNew else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard !ffmpeg.isInstalled, !showingWhatsNew, !showingSettings else { return }
            showingFFmpegPrompt = true
        }
    }

    private var ffmpegDownloadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    ffmpeg.state == .verifying ? "正在校验组件" : "正在下载完整 FFmpeg",
                    systemImage: "shippingbox.fill"
                )
                .font(.headline)
                Spacer()
                Text("\(Int(ffmpeg.progress * 100))%")
                    .font(.subheadline.bold().monospacedDigit())
            }
            ProgressView(value: ffmpeg.progress)
                .tint(.indigo)
            HStack {
                Text(ffmpeg.transferredText)
                Spacer()
                Text(ffmpeg.speedText)
                Text(ffmpeg.etaText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if ffmpeg.state == .downloading {
                Button("取消组件下载", role: .destructive) { ffmpeg.cancelInstall() }
                    .font(.caption.weight(.semibold))
            }
        }
        .glassCard()
    }

    private var appBackground: some View {
        ZStack {
            Color(red: 0.97, green: 0.985, blue: 1.0)
            LinearGradient(
                colors: [
                    Color.white,
                    Color(red: 0.90, green: 0.96, blue: 1.0),
                    Color(red: 0.94, green: 0.92, blue: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.cyan.opacity(0.14))
                .frame(width: 260, height: 260)
                .blur(radius: 24)
                .offset(x: 150, y: -260)
            Circle()
                .fill(Color.indigo.opacity(0.10))
                .frame(width: 300, height: 300)
                .blur(radius: 36)
                .offset(x: -170, y: 320)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.13, green: 0.48, blue: 1.0), .indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                    .shadow(color: .blue.opacity(0.3), radius: 14, y: 8)
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("本地下载器")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                Text("清晰画质 · 后台下载 · 自动存相册")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.72))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.58), in: Circle())
                    .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
        .padding(.vertical, 8)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("新建下载")
                        .font(.title3.weight(.bold))
                    Text("粘贴 YouTube 视频或 Shorts 链接")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "link.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }

            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)
                TextField("https://youtube.com/…", text: $model.urlText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(1...3)

                Button {
                    model.urlText = UIPasteboard.general.string ?? ""
                } label: {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("粘贴")
            }
            .padding(11)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.9), lineWidth: 1) }

            Picker("类型", selection: $model.kind) {
                ForEach(DownloadKind.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isBusy)

            if model.kind == .video {
                HStack {
                    Label("视频画质", systemImage: "sparkles.tv")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("画质", selection: $model.quality) {
                        ForEach(VideoQuality.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.isBusy)
                }
                .padding(13)
                .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }

            Button(action: model.start) {
                HStack(spacing: 9) {
                    if model.isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    Text(model.isBusy ? "正在处理，请稍候" : "开始下载")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(.white)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.08, green: 0.52, blue: 1.0), .indigo],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .shadow(color: .blue.opacity(0.28), radius: 16, y: 9)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(model.isBusy || model.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
        }
        .glassCard()
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("下载任务")
                        .font(.title3.weight(.bold))
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.isBusy ? Color.orange : (model.progress >= 1 ? Color.green : Color.secondary.opacity(0.45)))
                        .frame(width: 7, height: 7)
                    Text(model.isBusy ? "进行中" : (model.progress >= 1 ? "已完成" : "等待中"))
                        .font(.caption2.weight(.bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.white.opacity(0.62), in: Capsule())
            }

            if model.isBusy, model.activePhase == .resolving {
                phaseProgress(
                    title: "本机解析",
                    value: model.resolveProgress,
                    icon: "iphone.gen3.radiowaves.left.and.right",
                    color: .blue
                )
            } else if model.isBusy, model.activePhase == .downloadingVideo {
                phaseProgress(
                    title: "视频 MP4",
                    value: model.videoProgress,
                    icon: "film.fill",
                    color: .blue
                )
            } else if model.isBusy, model.activePhase == .downloadingAudio {
                phaseProgress(
                    title: "AAC 音频",
                    value: model.audioProgress,
                    icon: "waveform",
                    color: .purple
                )
            } else if model.isBusy, model.activePhase == .converting {
                phaseProgress(
                    title: "FFmpeg 合并 MP4",
                    value: model.conversionProgress,
                    icon: "iphone.gen3",
                    color: .green
                )
            }

            if model.isBusy,
               model.activePhase == .downloadingVideo ||
               model.activePhase == .downloadingAudio ||
               model.activePhase == .converting {
                HStack(spacing: 10) {
                    metric(title: "速度", value: model.speedText, icon: "speedometer")
                    metric(title: "时间", value: model.etaText, icon: "clock")
                }
                if model.transferredText != "--", model.activePhase != .converting {
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive.fill")
                        Text(model.transferredText)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            if let file = model.latestFile {
                Button {
                    shareItem = ShareItem(fileURL: file)
                } label: {
                    Label("打开分享与导出", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .buttonBorderShape(.roundedRectangle(radius: 14))
            }
        }
        .glassCard()
    }

    private func phaseProgress(
        title: String,
        value: Double,
        icon: String,
        color: Color
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(color)
            }
            VStack(spacing: 7) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Text("\(Int(min(1, max(0, value)) * 100))%")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(color)
                }
                ProgressView(value: value)
                    .tint(color)
                    .scaleEffect(x: 1, y: 1.25, anchor: .center)
            }
        }
        .padding(12)
        .background(.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.72), lineWidth: 1) }
    }

    private func metric(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
                .background(.blue.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.monospacedDigit().weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本机文件")
                        .font(.title3.weight(.bold))
                    Text("转换完成的文件会保留在这里")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.savedFiles.count)")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
                    .frame(width: 32, height: 32)
                    .background(.blue.opacity(0.1), in: Circle())
            }

            if model.savedFiles.isEmpty {
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(.blue.opacity(0.08))
                            .frame(width: 66, height: 66)
                        Image(systemName: "tray.fill")
                            .font(.system(size: 27))
                            .foregroundStyle(.blue.opacity(0.7))
                    }
                    Text("暂无文件").font(.headline)
                    Text("粘贴链接，开始你的第一次下载")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            } else {
                ForEach(model.savedFiles, id: \.self) { file in
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(file.pathExtension.lowercased() == "m4a" ? Color.purple.opacity(0.12) : Color.blue.opacity(0.12))
                                .frame(width: 46, height: 46)
                            Image(systemName: file.pathExtension.lowercased() == "m4a" ? "waveform" : "film.fill")
                                .foregroundStyle(file.pathExtension.lowercased() == "m4a" ? Color.purple : Color.blue)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.deletingPathExtension().lastPathComponent)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text(model.fileSizeText(file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button { shareItem = ShareItem(fileURL: file) } label: {
                                Label("分享或导出", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) { model.delete(file) } label: {
                                Label("删除文件", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 36, height: 36)
                                .background(.white.opacity(0.62), in: Circle())
                        }
                    }
                    .padding(11)
                    .background(.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
            }
        }
        .glassCard()
    }
}

private struct SettingsView: View {
    @ObservedObject var model: DownloadViewModel
    @ObservedObject var ffmpeg: FFmpegComponentManager
    @Environment(\.dismiss) private var dismiss
    @State private var cookieConfigured = YouTubeCookieStore.hasCookie

    var body: some View {
        NavigationStack {
            Form {
                Section("下载") {
                    Toggle("允许蜂窝网络下载", isOn: $model.allowsCellular)
                    Toggle("下载完成通知", isOn: $model.notificationsEnabled)
                    Toggle("灵动岛与锁屏进度", isOn: $model.liveActivityEnabled)
                }

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: ffmpeg.isInstalled ? "checkmark.seal.fill" : "shippingbox")
                            .foregroundStyle(ffmpeg.isInstalled ? Color.green : Color.indigo)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ffmpeg.isInstalled ? "完整 FFmpeg 已安装" : "完整 FFmpeg 未安装")
                                .font(.subheadline.weight(.semibold))
                            Text(ffmpeg.isInstalled ? "\(FFmpegComponentManager.componentVersion) · \(ffmpeg.installedSizeText)" : "高清视频合并需要下载约 17.1 MB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if ffmpeg.state == .downloading || ffmpeg.state == .verifying {
                        ProgressView(value: ffmpeg.progress)
                            .tint(.indigo)
                        LabeledContent(ffmpeg.speedText, value: ffmpeg.etaText)
                            .font(.caption)
                        Text(ffmpeg.transferredText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("取消下载", role: .destructive) { ffmpeg.cancelInstall() }
                    } else if ffmpeg.isInstalled {
                        Button("重新下载完整组件") {
                            ffmpeg.remove()
                            ffmpeg.install(allowsCellular: model.allowsCellular)
                        }
                        Button("删除组件", role: .destructive) { ffmpeg.remove() }
                    } else {
                        Button("下载完整 FFmpeg 组件") {
                            ffmpeg.install(allowsCellular: model.allowsCellular)
                        }
                    }

                    if case .failed(let message) = ffmpeg.state {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("本机合并组件")
                } footer: {
                    Text("组件保存在 App 沙盒中。音视频全部下载完成后，由 iPhone 使用 FFmpeg 无损封装为 MP4。")
                }

                Section {
                    NavigationLink {
                        CookieSettingsView {
                            cookieConfigured = YouTubeCookieStore.hasCookie
                        }
                    } label: {
                        Label {
                            HStack {
                                Text("YouTube Cookie")
                                Spacer()
                                Text(cookieConfigured ? "已设置" : "未设置")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(cookieConfigured ? Color.green : Color.orange)
                            }
                        } icon: {
                            Image(systemName: cookieConfigured ? "key.fill" : "key")
                                .foregroundStyle(cookieConfigured ? Color.green : Color.orange)
                        }
                    }
                } header: {
                    Text("本机 YouTube 解析")
                } footer: {
                    Text("解析在 iPhone 本机完成，不再连接自建解析服务器。遇到“需要登录”时粘贴 Cookie；Cookie 只保存在本机钥匙串。")
                }

                Section("关于") {
                    NavigationLink {
                        FeatureGuideView()
                    } label: {
                        Label("功能介绍", systemImage: "list.bullet.rectangle")
                    }
                    Link(destination: URL(string: "https://github.com/5488-ux/YouTubeNativeDownloader")!) {
                        Label("打开 GitHub", systemImage: "link")
                    }
                    LabeledContent("版本", value: appVersion)
                }

                Section("诊断") {
                    NavigationLink {
                        DiagnosticLogView()
                    } label: {
                        Label("详细错误日志", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section("更新") {
                    NavigationLink {
                        ChangelogView()
                    } label: {
                        Label {
                            HStack {
                                Text("更新日志")
                                Spacer()
                                Text("v\(ReleaseNote.current.version)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [.white, Color(red: 0.91, green: 0.96, blue: 1.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .tint(.blue)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                cookieConfigured = YouTubeCookieStore.hasCookie
            }
        }
        .preferredColorScheme(.light)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "19"
        return "\(version) (\(build))"
    }
}

private struct CookieSettingsView: View {
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cookieText = ""
    @State private var message: String?
    @State private var showingMessage = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $cookieText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 190)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
            } header: {
                Text("粘贴 Cookie")
            } footer: {
                Text("支持 Cookie 请求头、Netscape cookies.txt 和常见 JSON 导出格式。App 不会把 Cookie 写入日志，也不会上传到自建服务器。")
            }

            Section {
                Button("保存到本机钥匙串") {
                    do {
                        try YouTubeCookieStore.save(cookieText)
                        cookieText = YouTubeCookieStore.load() ?? ""
                        onChange()
                        message = cookieText.isEmpty ? "Cookie 已清空" : "Cookie 已安全保存"
                    } catch {
                        message = error.localizedDescription
                    }
                    showingMessage = true
                }
                .disabled(cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if YouTubeCookieStore.hasCookie {
                    Button("删除 Cookie", role: .destructive) {
                        YouTubeCookieStore.delete()
                        cookieText = ""
                        onChange()
                        message = "Cookie 已删除"
                        showingMessage = true
                    }
                }
            }

            Section("怎么获取") {
                Text("在你自己的浏览器登录 YouTube，使用 Cookie 导出工具复制 youtube.com 的 Cookie，再粘贴到这里。Cookie 等同登录凭证，不要发给任何人。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("YouTube Cookie")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            cookieText = YouTubeCookieStore.load() ?? ""
        }
        .alert("Cookie", isPresented: $showingMessage) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(message ?? "操作完成")
        }
    }
}

private struct ReleaseNote: Identifiable {
    let version: String
    let title: String
    let changes: [String]

    var id: String { version }

    static let all: [ReleaseNote] = [
        ReleaseNote(
            version: "4.0",
            title: "完全本机解析",
            changes: [
                "移除自建 yt-dlp 解析接口和服务器媒体中转。",
                "由 iPhone 直接请求 YouTube Innertube 并选择 H.264 与 AAC 格式。",
                "设置中可粘贴 YouTube Cookie，并只保存到本机钥匙串。",
                "视频、音频下载以及 FFmpeg 合并全部在手机完成。"
            ]
        ),
        ReleaseNote(
            version: "3.2",
            title: "明亮界面与完整更新记录",
            changes: [
                "提高卡片、表单和文字对比度，解决界面灰蒙蒙的问题。",
                "更新日志按版本折叠，默认收起，点击版本后展开。",
                "每个新版本首次启动显示一次更新内容弹窗。",
                "解析连接中断、超时及 Cloudflare 5xx 错误自动重试。"
            ]
        ),
        ReleaseNote(
            version: "3.1",
            title: "标准 WASI FFmpeg",
            changes: [
                "替换不兼容的 a-Shell 私有组件，改用标准 WASI FFmpeg 5.1.7。",
                "使用独立沙盒工作目录无损合并 MP4。",
                "组件断线自动重试，合并错误记录输入与输出字节数。"
            ]
        ),
        ReleaseNote(
            version: "3.0",
            title: "可下载的完整 FFmpeg 组件",
            changes: [
                "IPA 不再内置 FFmpeg，用户可在首次启动或设置中下载完整组件。",
                "增加组件下载进度、速度、剩余时间、SHA-256 校验、重装和删除。",
                "视频和 AAC 下载完成后使用 FFmpeg 无损合并为 MP4。"
            ]
        ),
        ReleaseNote(
            version: "2.9",
            title: "音视频时间轴校验",
            changes: [
                "记录视频和音频轨道的开始时间与时长。",
                "导出后检查成品时长、视频轨和音频轨，发现异常时给出明确错误。",
                "提高锁屏实时活动文字对比度。"
            ]
        ),
        ReleaseNote(
            version: "2.7",
            title: "下载阶段与界面优化",
            changes: [
                "服务器解析、视频、AAC 和本机转换只显示当前阶段进度。",
                "视频与音频使用独立进度，避免进度条挤在一起。",
                "重做下载入口、任务状态与本机文件卡片。"
            ]
        ),
        ReleaseNote(
            version: "2.3",
            title: "自动保存与详细诊断",
            changes: [
                "视频转换完成后自动保存到照片图库。",
                "增加可复制、刷新和清空的持久化详细错误日志。",
                "保留 App 本机文件，支持再次分享和删除。"
            ]
        ),
        ReleaseNote(
            version: "2.0",
            title: "后台下载与灵动岛",
            changes: [
                "使用系统后台 URLSession，锁屏或切到后台后继续传输。",
                "显示实时速度、已下载大小和预计剩余时间。",
                "增加灵动岛、锁屏 Live Activity 和完成通知。"
            ]
        ),
        ReleaseNote(
            version: "1.9",
            title: "服务器中转与 MOV 输出",
            changes: [
                "Google 直连失败时自动切换服务器临时中转。",
                "视频与 AAC 完整下载后在 iPhone 本机合并。",
                "增加转换进度和照片保存入口。"
            ]
        ),
        ReleaseNote(
            version: "1.0",
            title: "首个原生版本",
            changes: [
                "原生 SwiftUI 下载界面。",
                "支持普通 YouTube、Shorts、youtu.be、Embed 和 Live 链接。",
                "支持最佳画质、1080P、720P、480P 及 M4A 音频。"
            ]
        )
    ]

    static let current = all[0]
}

private struct WhatsNewView: View {
    let release: ReleaseNote
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [.white, Color(red: 0.88, green: 0.95, blue: 1.0)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 22) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.gradient)
                            .frame(width: 82, height: 82)
                            .shadow(color: .blue.opacity(0.28), radius: 18, y: 9)
                        Image(systemName: "sparkles")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    VStack(spacing: 6) {
                        Text("已更新到 \(release.version)")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                        Text(release.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.black.opacity(0.62))
                    }

                    VStack(alignment: .leading, spacing: 15) {
                        ForEach(release.changes, id: \.self) { change in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                                    .font(.system(size: 18, weight: .bold))
                                Text(change)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.black.opacity(0.82))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(19)
                    .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .blue.opacity(0.09), radius: 20, y: 10)

                    Button(action: dismiss) {
                        Text("知道了")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .foregroundStyle(.white)
                            .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(22)
            }
            .navigationBarHidden(true)
        }
        .preferredColorScheme(.light)
    }
}

private struct ChangelogView: View {
    var body: some View {
        List {
            ForEach(ReleaseNote.all) { release in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 11) {
                        Text(release.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.black.opacity(0.86))
                        ForEach(release.changes, id: \.self) { change in
                            HStack(alignment: .top, spacing: 9) {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 6)
                                Text(change)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.black.opacity(0.72))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 5)
                } label: {
                    HStack(spacing: 10) {
                        Text("版本 \(release.version)")
                            .font(.headline)
                            .foregroundStyle(Color.black.opacity(0.9))
                        Spacer()
                        if release.version == ReleaseNote.current.version {
                            Text("当前")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.blue, in: Capsule())
                        }
                    }
                }
                .tint(.blue)
                .listRowBackground(Color.white.opacity(0.96))
            }
        }
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [.white, Color(red: 0.91, green: 0.96, blue: 1.0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .navigationTitle("更新日志")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
    }
}

private struct FeatureGuideView: View {
    var body: some View {
        List {
            Section("视频与音频") {
                feature(
                    "多种 YouTube 链接",
                    "支持普通视频、Shorts、youtu.be、Embed 和 Live 链接。",
                    "link",
                    .blue
                )
                feature(
                    "最高画质下载",
                    "支持最佳画质、1080P、720P 和 480P，优先选择 iPhone 兼容的 H.264。",
                    "sparkles.tv",
                    .indigo
                )
                feature(
                    "视频或纯音频",
                    "视频输出 MP4，纯音频输出 M4A；视频和 AAC 音频分别完整下载。",
                    "film.fill",
                    .purple
                )
            }

            Section("下载体验") {
                feature(
                    "分阶段实时进度",
                    "本机解析、视频、AAC 和 FFmpeg 合并按当前阶段显示进度、速度与剩余时间。",
                    "chart.bar.fill",
                    .blue
                )
                feature(
                    "后台与锁屏下载",
                    "使用系统后台下载，切换 App 或锁屏后仍可继续传输。",
                    "arrow.down.app.fill",
                    .cyan
                )
                feature(
                    "灵动岛与通知",
                    "支持 Live Activity、锁屏任务进度以及下载完成或失败通知。",
                    "iphone.radiowaves.left.and.right",
                    .orange
                )
            }

            Section("iPhone 本机处理") {
                feature(
                    "完整 FFmpeg 本机合并",
                    "首次启动可下载完整组件；视频和 AAC 下载完成后，由 iPhone 使用 FFmpeg 无损合并，不上传成品。",
                    "iphone.gen3",
                    .green
                )
                feature(
                    "自动保存照片",
                    "MP4 合并完成后自动写入照片图库，同时在 App 文件中保留一份备份。",
                    "photo.on.rectangle.angled",
                    .green
                )
                feature(
                    "本机文件管理",
                    "可以查看文件大小、再次分享或导出，也可以删除不需要的文件。",
                    "folder.fill",
                    .orange
                )
            }

            Section("设置与诊断") {
                feature(
                    "网络与后台设置",
                    "可控制蜂窝网络、完成通知、灵动岛和锁屏进度。",
                    "gearshape.2.fill",
                    .gray
                )
                feature(
                    "本机解析与 Cookie",
                    "iPhone 直接解析 YouTube；需要登录时可把 Cookie 安全保存到本机钥匙串。",
                    "key.fill",
                    .blue
                )
                feature(
                    "详细错误日志",
                    "记录解析、HTTP、下载、转换和照片保存错误，支持复制、刷新与清空。",
                    "doc.text.magnifyingglass",
                    .red
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.93, green: 0.96, blue: 1.0))
        .navigationTitle("功能介绍")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func feature(_ title: String, _ detail: String, _ icon: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct DiagnosticLogView: View {
    @State private var logText = "正在读取…"
    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(logText)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("详细错误日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    logText = DiagnosticLogger.shared.text()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                Button {
                    UIPasteboard.general.string = logText
                    copied = true
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                Button(role: .destructive) {
                    DiagnosticLogger.shared.clear()
                    logText = "暂无日志"
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .onAppear { logText = DiagnosticLogger.shared.text() }
        .alert("已复制", isPresented: $copied) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("完整日志已复制到剪贴板。")
        }
    }
}

private extension View {
    func glassCard() -> some View {
        padding(17)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.98), Color(red: 0.95, green: 0.98, blue: 1.0)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white, Color.blue.opacity(0.14)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.blue.opacity(0.10), radius: 22, y: 12)
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let fileURL: URL
}

#Preview {
    ContentView()
}
