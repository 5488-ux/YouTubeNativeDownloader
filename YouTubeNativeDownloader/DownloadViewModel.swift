import Combine
import Foundation

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var urlText = ""
    @Published var kind: DownloadKind = .video
    @Published var quality: VideoQuality = .best
    @Published private(set) var isBusy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var statusText = "粘贴链接后开始"
    @Published private(set) var speedText = "--"
    @Published private(set) var etaText = "--"
    @Published private(set) var transferredText = "--"
    @Published private(set) var errorText: String?
    @Published private(set) var latestFile: URL?
    @Published private(set) var savedFiles: [URL] = []

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Keys.serverURL) }
    }
    @Published var allowsCellular: Bool {
        didSet { UserDefaults.standard.set(allowsCellular, forKey: Keys.allowsCellular) }
    }
    @Published var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
            if notificationsEnabled { NotificationManager.requestAuthorization() }
        }
    }
    @Published var liveActivityEnabled: Bool {
        didSet { UserDefaults.standard.set(liveActivityEnabled, forKey: Keys.liveActivityEnabled) }
    }

    private let resolver = VideoResolver()
    private var lastActivityUpdate = Date.distantPast

    init() {
        let defaults = UserDefaults.standard
        serverURL = defaults.string(forKey: Keys.serverURL)
            ?? "https://youtube.789113.cn/ios-api/resolve"
        allowsCellular = defaults.object(forKey: Keys.allowsCellular) as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        liveActivityEnabled = defaults.object(forKey: Keys.liveActivityEnabled) as? Bool ?? true
        refreshFiles()
        if notificationsEnabled { NotificationManager.requestAuthorization() }
    }

    func start() {
        guard !isBusy else { return }
        let trimmedServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: trimmedServer),
              let scheme = endpoint.scheme?.lowercased(),
              ["https", "http"].contains(scheme) else {
            errorText = DownloaderError.invalidServerURL.localizedDescription
            return
        }

        errorText = nil
        latestFile = nil
        isBusy = true
        progress = 0
        speedText = "--"
        etaText = "--"
        transferredText = "--"
        statusText = "服务器正在解析格式"

        Task {
            do {
                let media = try await resolver.resolve(
                    urlText: urlText,
                    quality: quality,
                    kind: kind,
                    endpoint: endpoint
                )
                DownloadActivityManager.shared.start(
                    title: media.title,
                    kind: kind.rawValue,
                    enabled: liveActivityEnabled
                )

                let output: URL
                switch kind {
                case .video:
                    guard let video = media.video else { throw DownloaderError.noCompatibleVideo }
                    let videoLength = max(0, video.contentLength ?? 0)
                    let audioLength = max(0, media.audio.contentLength ?? 0)
                    let knownTotal = videoLength + audioLength
                    let videoWeight = knownTotal > 0 ? Double(videoLength) / Double(knownTotal) * 0.96 : 0.80
                    let audioWeight = 0.96 - videoWeight

                    statusText = resolutionText(video) + " · 下载视频"
                    let videoFile = try await downloadWithFallback(
                        source: video
                    ) { [weak self] value in
                        Task { @MainActor in
                            self?.applyProgress(value, offset: 0, weight: videoWeight, phase: "下载视频")
                        }
                    }

                    statusText = "下载 AAC 音频"
                    let audioFile = try await downloadWithFallback(
                        source: media.audio
                    ) { [weak self] value in
                        Task { @MainActor in
                            self?.applyProgress(value, offset: videoWeight, weight: audioWeight, phase: "下载音频")
                        }
                    }

                    statusText = "本机无损合并音视频"
                    progress = 0.97
                    speedText = "本机处理"
                    etaText = "即将完成"
                    updateActivity(force: true)
                    output = try await MediaFileBuilder.merge(
                        videoURL: videoFile,
                        audioURL: audioFile,
                        title: media.title
                    )
                    try? FileManager.default.removeItem(at: videoFile)
                    try? FileManager.default.removeItem(at: audioFile)

                case .audio:
                    statusText = "下载 AAC 音频"
                    let audioFile = try await downloadWithFallback(
                        source: media.audio
                    ) { [weak self] value in
                        Task { @MainActor in
                            self?.applyProgress(value, offset: 0, weight: 0.98, phase: "下载音频")
                        }
                    }
                    output = try MediaFileBuilder.saveAudio(sourceURL: audioFile, title: media.title)
                }

                progress = 1
                speedText = "已完成"
                etaText = "0 秒"
                statusText = "下载完成，已保存到 App 文件"
                latestFile = output
                refreshFiles()
                DownloadActivityManager.shared.end(finalStatus: "下载完成")
                NotificationManager.post(
                    title: "下载完成",
                    body: output.lastPathComponent,
                    enabled: notificationsEnabled
                )
            } catch {
                errorText = error.localizedDescription
                statusText = "下载失败"
                speedText = "--"
                etaText = "--"
                DownloadActivityManager.shared.end(finalStatus: "下载失败")
                NotificationManager.post(
                    title: "下载失败",
                    body: error.localizedDescription,
                    enabled: notificationsEnabled
                )
            }
            isBusy = false
        }
    }

    func cancelMessage() {
        errorText = nil
    }

    func resetServerURL() {
        serverURL = "https://youtube.789113.cn/ios-api/resolve"
    }

    func refreshFiles() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        savedFiles = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
    }

    func delete(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        if latestFile == file { latestFile = nil }
        refreshFiles()
    }

    func fileSizeText(_ file: URL) -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func applyProgress(_ value: TransferProgress, offset: Double, weight: Double, phase: String) {
        progress = min(0.96, offset + value.fraction * weight)
        speedText = value.bytesPerSecond > 1
            ? Self.speedFormatter.string(fromByteCount: Int64(value.bytesPerSecond)) + "/s"
            : "测速中"
        etaText = value.remainingSeconds.map(Self.durationText) ?? "计算中"
        if value.totalBytes > 0 {
            transferredText = "\(Self.byteFormatter.string(fromByteCount: value.bytesWritten)) / \(Self.byteFormatter.string(fromByteCount: value.totalBytes))"
        } else {
            transferredText = Self.byteFormatter.string(fromByteCount: value.bytesWritten)
        }
        statusText = phase
        updateActivity(force: false)
    }

    private func downloadWithFallback(
        source: MediaSource,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> URL {
        do {
            return try await DownloadTransfer().download(
                source: source,
                allowsCellular: allowsCellular,
                progress: progress
            )
        } catch {
            guard let fallbackURL = source.fallbackURL else { throw error }
            statusText = "Google 直连不可用，切换服务器中转"
            let fallbackSource = MediaSource(
                url: fallbackURL,
                fallbackURL: nil,
                contentLength: source.contentLength,
                codec: source.codec,
                width: source.width,
                height: source.height,
                fps: source.fps,
                bitrate: source.bitrate
            )
            return try await DownloadTransfer().download(
                source: fallbackSource,
                allowsCellular: allowsCellular,
                progress: progress
            )
        }
    }

    private func updateActivity(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastActivityUpdate) >= 1 else { return }
        lastActivityUpdate = now
        DownloadActivityManager.shared.update(
            progress: progress,
            speedText: speedText,
            etaText: etaText,
            statusText: statusText
        )
    }

    private func resolutionText(_ source: MediaSource) -> String {
        guard let width = source.width, let height = source.height else { return "H.264" }
        let fps = source.fps.map { " · \($0)fps" } ?? ""
        return "\(width)×\(height)\(fps) · H.264"
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value < 60 { return "剩余 \(value) 秒" }
        if value < 3600 { return "剩余 \(value / 60) 分 \(value % 60) 秒" }
        return "剩余 \(value / 3600) 小时 \((value % 3600) / 60) 分"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    private static let speedFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter
    }()

    private enum Keys {
        static let serverURL = "settings.serverURL"
        static let allowsCellular = "settings.allowsCellular"
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let liveActivityEnabled = "settings.liveActivityEnabled"
    }
}
