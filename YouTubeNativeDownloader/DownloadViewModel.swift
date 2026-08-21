import Combine
import Foundation
import Photos
import UIKit

enum DownloadTaskPhase: Equatable {
    case idle
    case resolving
    case downloadingVideo
    case downloadingAudio
    case converting
    case saving
    case completed
    case failed
}
@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var urlText = ""
    @Published var kind: DownloadKind = .video
    @Published var quality: VideoQuality = .best
    @Published var audioLanguage: AudioLanguage {
        didSet { UserDefaults.standard.set(audioLanguage.rawValue, forKey: Keys.audioLanguage) }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var resolveProgress = 0.0
    @Published private(set) var videoProgress = 0.0
    @Published private(set) var audioProgress = 0.0
    @Published private(set) var conversionProgress = 0.0
    @Published private(set) var statusText = "粘贴链接后开始"
    @Published private(set) var speedText = "--"
    @Published private(set) var etaText = "--"
    @Published private(set) var transferredText = "--"
    @Published private(set) var alertTitle = "下载失败"
    @Published private(set) var errorText: String?
    @Published private(set) var latestFile: URL?
    @Published private(set) var savedFiles: [URL] = []
    @Published private(set) var activePhase: DownloadTaskPhase = .idle

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
    private var resolverProgressTask: Task<Void, Never>?
    private var activityTitle = "YouTube 下载任务"

    init() {
        let defaults = UserDefaults.standard
        audioLanguage = AudioLanguage(rawValue: defaults.string(forKey: Keys.audioLanguage) ?? "")
            ?? .originalEnglish
        serverURL = defaults.string(forKey: Keys.serverURL)
            ?? "https://youtube.789113.cn/ios-api/resolve"
        allowsCellular = defaults.object(forKey: Keys.allowsCellular) as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        liveActivityEnabled = defaults.object(forKey: Keys.liveActivityEnabled) as? Bool ?? true
        NotificationManager.configure()
        DownloadActivityManager.shared.dismissAll()
        refreshFiles()
        if notificationsEnabled { NotificationManager.requestAuthorization() }
    }

    func start() {
        guard !isBusy else { return }
        if kind == .video && !FFmpegComponentManager.shared.isInstalled {
            alertTitle = "需要合并组件"
            errorText = DownloaderError.componentMissing.localizedDescription
            return
        }
        let trimmedServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: trimmedServer),
              let scheme = endpoint.scheme?.lowercased(),
              ["https", "http"].contains(scheme) else {
            errorText = DownloaderError.invalidServerURL.localizedDescription
            return
        }

        errorText = nil
        alertTitle = "下载失败"
        latestFile = nil
        isBusy = true
        progress = 0
        resolveProgress = 0.04
        videoProgress = 0
        audioProgress = 0
        conversionProgress = 0
        speedText = "--"
        etaText = "--"
        transferredText = "--"
        statusText = "服务器正在解析格式"
        activityTitle = "YouTube 下载任务"
        activePhase = .resolving
        startResolverProgress()
        DownloadActivityManager.shared.start(
            title: activityTitle,
            kind: kind.rawValue,
            enabled: liveActivityEnabled
        )
        updateActivity(force: true)
        DiagnosticLogger.shared.beginSession(
            urlText: urlText,
            endpoint: endpoint,
            kind: kind,
            quality: quality
        )
        DiagnosticLogger.shared.info("开始请求解析服务器; audioLanguage=\(audioLanguage.apiValue)")

        Task {
            do {
                let media = try await resolver.resolve(
                    urlText: urlText,
                    quality: quality,
                    kind: kind,
                    audioLanguage: audioLanguage,
                    endpoint: endpoint
                )
                stopResolverProgress(completed: true)
                activityTitle = media.title
                updateActivity(force: true)
                DiagnosticLogger.shared.info("解析成功; videoID=\(media.videoID); title=\(media.title)")

                let output: URL
                switch kind {
                case .video:
                    guard let video = media.video else { throw DownloaderError.noCompatibleVideo }
                    let videoLength = max(0, video.contentLength ?? 0)
                    let audioLength = max(0, media.audio.contentLength ?? 0)
                    let knownTotal = videoLength + audioLength
                    let videoWeight = knownTotal > 0 ? Double(videoLength) / Double(knownTotal) * 0.90 : 0.75
                    let audioWeight = 0.90 - videoWeight

                    statusText = resolutionText(video) + " · 下载视频"
                    activePhase = .downloadingVideo
                    DiagnosticLogger.shared.info("开始下载视频; \(sourceDescription(video))")
                    let videoFile = try await downloadDirect(
                        source: video,
                        mediaRole: .video,
                        endpoint: endpoint
                    ) { [weak self] value in
                        Task { @MainActor in
                            self?.applyProgress(value, offset: 0, weight: videoWeight, phase: "下载视频")
                        }
                    }
                    videoProgress = 1
                    updateActivity(force: true)

                    statusText = "下载 AAC 音频"
                    activePhase = .downloadingAudio
                    DiagnosticLogger.shared.info("开始下载音频; \(sourceDescription(media.audio))")
                    let audioFile = try await downloadDirect(
                        source: media.audio,
                        mediaRole: .audio,
                        endpoint: endpoint
                    ) { [weak self] value in
                        Task { @MainActor in
                            self?.applyProgress(value, offset: videoWeight, weight: audioWeight, phase: "下载音频")
                        }
                    }
                    audioProgress = 1
                    updateActivity(force: true)

                    statusText = "FFmpeg 正在合并 MP4"
                    activePhase = .converting
                    DiagnosticLogger.shared.info("音视频下载完成，开始本机 FFmpeg WASM 合并")
                    progress = 0.90
                    conversionProgress = 0
                    speedText = "本机合并"
                    etaText = "合并 0%"
                    updateActivity(force: true)

                    let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FFmpeg MP4 merge")
                    defer {
                        if backgroundTask != .invalid {
                            UIApplication.shared.endBackgroundTask(backgroundTask)
                        }
                    }
                    output = try await FFmpegWasmRunner.mergeToMP4(
                        videoURL: videoFile,
                        audioURL: audioFile,
                        title: media.title
                    ) { [weak self] conversionProgress in
                        Task { @MainActor in
                            guard let self else { return }
                            let percent = Int(conversionProgress * 100)
                            self.progress = 0.90 + conversionProgress * 0.09
                            self.conversionProgress = conversionProgress
                            self.statusText = "FFmpeg 正在合并 MP4 · \(percent)%"
                            self.speedText = "本机合并"
                            self.etaText = "合并 \(percent)%"
                            self.updateActivity(force: false)
                        }
                    }
                    try? FileManager.default.removeItem(at: videoFile)
                    try? FileManager.default.removeItem(at: audioFile)
                    conversionProgress = 1
                    DiagnosticLogger.shared.info("FFmpeg MP4 合并完成; file=\(output.lastPathComponent); bytes=\(fileBytes(output))")

                case .audio:
                    statusText = "下载 AAC 音频"
                    activePhase = .downloadingAudio
                    DiagnosticLogger.shared.info("开始下载音频; \(sourceDescription(media.audio))")
                    let audioFile = try await downloadDirect(
                        source: media.audio,
                        mediaRole: .audio,
                        endpoint: endpoint
                    ) { [weak self] value in
                        Task { @MainActor in
                            self?.applyProgress(value, offset: 0, weight: 0.98, phase: "下载音频")
                        }
                    }
                    audioProgress = 1
                    updateActivity(force: true)
                    output = try MediaFileBuilder.saveAudio(sourceURL: audioFile, title: media.title)
                    DiagnosticLogger.shared.info("音频保存完成; file=\(output.lastPathComponent); bytes=\(fileBytes(output))")
                }

                latestFile = output
                refreshFiles()
                progress = 0.995
                activePhase = .saving
                speedText = "保存中"
                etaText = "即将完成"

                var notificationTitle = "下载完成"
                var notificationBody = output.lastPathComponent
                if kind == .video {
                    statusText = "正在自动保存 MP4 到照片"
                    updateActivity(force: true)
                    do {
                        try await saveVideoToPhotos(output)
                        DiagnosticLogger.shared.info("照片图库保存成功")
                        statusText = "完成，MP4 已自动保存到照片"
                        notificationBody = "已保存到照片：\(output.lastPathComponent)"
                    } catch {
                        DiagnosticLogger.shared.error(error, stage: "保存到照片")
                        alertTitle = "自动保存失败"
                        errorText = error.localizedDescription
                        statusText = "MP4 已完成，但自动保存到照片失败"
                        notificationTitle = "MP4 已下载"
                        notificationBody = "照片保存失败，文件仍保留在 App 文件中"
                    }
                } else {
                    statusText = "下载完成，音频已保存到 App 文件"
                }

                progress = 1
                activePhase = .completed
                speedText = "已完成"
                etaText = "0 秒"
                DownloadActivityManager.shared.end(finalStatus: "下载完成")
                NotificationManager.post(
                    title: notificationTitle,
                    body: notificationBody,
                    enabled: notificationsEnabled
                )
            } catch {
                stopResolverProgress(completed: false)
                activePhase = .failed
                DiagnosticLogger.shared.error(error, stage: statusText)
                alertTitle = "下载失败"
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

    private func startResolverProgress() {
        resolverProgressTask?.cancel()
        resolverProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, let self else { return }
                let remaining = max(0, 0.92 - self.resolveProgress)
                self.resolveProgress = min(0.92, self.resolveProgress + max(0.012, remaining * 0.14))
                self.statusText = "服务器正在解析格式"
                self.updateActivity(force: false)
            }
        }
    }

    private func stopResolverProgress(completed: Bool) {
        resolverProgressTask?.cancel()
        resolverProgressTask = nil
        if completed { resolveProgress = 1 }
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
        if phase == "下载视频" {
            videoProgress = value.fraction
        } else if phase == "下载音频" {
            audioProgress = value.fraction
        }
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

    private func downloadDirect(
        source: MediaSource,
        mediaRole: DownloadMediaRole,
        endpoint: URL,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> URL {
        do {
            return try await downloadWithFallbacks(source: source, progress: progress)
        } catch {
            DiagnosticLogger.shared.error(error, stage: "后台下载恢复失败，准备刷新临时链接")
            statusText = "下载连接失效，服务器重新解析"
            activePhase = .resolving
            resolveProgress = 0.04
            startResolverProgress()
            updateActivity(force: true)

            let refreshedMedia: ResolvedMedia
            do {
                refreshedMedia = try await resolver.resolve(
                    urlText: urlText,
                    quality: quality,
                    kind: kind,
                    audioLanguage: audioLanguage,
                    endpoint: endpoint
                )
                stopResolverProgress(completed: true)
            } catch {
                stopResolverProgress(completed: false)
                throw error
            }

            activityTitle = refreshedMedia.title
            let refreshedSource: MediaSource
            switch mediaRole {
            case .video:
                guard let video = refreshedMedia.video else {
                    throw DownloaderError.noCompatibleVideo
                }
                refreshedSource = video
                activePhase = .downloadingVideo
                statusText = resolutionText(video) + " · 重新下载视频"
            case .audio:
                refreshedSource = refreshedMedia.audio
                activePhase = .downloadingAudio
                statusText = "重新下载 AAC 音频"
            }
            updateActivity(force: true)
            DiagnosticLogger.shared.info(
                "服务器已刷新临时媒体地址; role=\(mediaRole.rawValue); " +
                "host=\(refreshedSource.url.host ?? "unknown")"
            )
            return try await downloadWithFallbacks(source: refreshedSource, progress: progress)
        }
    }

    private func downloadWithFallbacks(
        source: MediaSource,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> URL {
        var candidates = [source]
        if let fallbackURL = source.fallbackURL,
           fallbackURL != source.url {
            candidates.append(copySource(source, replacingURL: fallbackURL))
        }

        var lastError: Error = DownloaderError.downloadFailed
        for (index, candidate) in candidates.enumerated() {
            do {
                if index > 0 {
                    DiagnosticLogger.shared.warning(
                        "切换备用下载地址; host=\(candidate.url.host ?? "unknown")"
                    )
                }
                return try await DownloadTransfer().download(
                    source: candidate,
                    allowsCellular: allowsCellular,
                    mode: .background,
                    progress: progress
                )
            } catch {
                lastError = error
                DiagnosticLogger.shared.error(
                    error,
                    stage: index == 0 ? "主后台下载失败" : "备用后台下载失败"
                )
            }
        }

        if UIApplication.shared.applicationState == .active {
            for candidate in candidates.reversed() {
                do {
                    DiagnosticLogger.shared.warning(
                        "后台会话均失败，切换前台下载兜底; host=\(candidate.url.host ?? "unknown")"
                    )
                    return try await DownloadTransfer().download(
                        source: candidate,
                        allowsCellular: allowsCellular,
                        mode: .foreground,
                        progress: progress
                    )
                } catch {
                    lastError = error
                    DiagnosticLogger.shared.error(error, stage: "前台下载兜底失败")
                }
            }
        }
        throw lastError
    }

    private func copySource(_ source: MediaSource, replacingURL url: URL) -> MediaSource {
        MediaSource(
            url: url,
            fallbackURL: nil,
            httpHeaders: source.httpHeaders,
            contentLength: source.contentLength,
            codec: source.codec,
            width: source.width,
            height: source.height,
            fps: source.fps,
            bitrate: source.bitrate,
            language: source.language,
            formatNote: source.formatNote
        )
    }

    private func updateActivity(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastActivityUpdate) >= 1 else { return }
        lastActivityUpdate = now
        DownloadActivityManager.shared.update(
            progress: progress,
            resolveProgress: resolveProgress,
            videoProgress: videoProgress,
            audioProgress: audioProgress,
            speedText: speedText,
            etaText: etaText,
            statusText: statusText,
            titleText: activityTitle
        )
    }

    private func resolutionText(_ source: MediaSource) -> String {
        guard let width = source.width, let height = source.height else { return "H.264" }
        let fps = source.fps.map { " · \($0)fps" } ?? ""
        return "\(width)×\(height)\(fps) · H.264"
    }

    private func sourceDescription(_ source: MediaSource) -> String {
        let size = source.contentLength.map { String($0) } ?? "unknown"
        let resolution = source.width.flatMap { width in
            source.height.map { "\(width)x\($0)" }
        } ?? "audio"
        let language = source.language ?? "unknown"
        let formatNote = source.formatNote ?? "none"
        return "host=\(source.url.host ?? "unknown"); codec=\(source.codec); resolution=\(resolution); bytes=\(size); language=\(language); note=\(formatNote); direct=true"
    }

    private func fileBytes(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func saveVideoToPhotos(_ fileURL: URL) async throws {
        var authorization = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if authorization == .notDetermined {
            authorization = await withCheckedContinuation {
                (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    continuation.resume(returning: status)
                }
            }
        }

        guard authorization == .authorized || authorization == .limited else {
            throw DownloaderError.photoPermissionDenied
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: DownloaderError.photoSaveFailed(
                        error?.localizedDescription ?? "照片图库没有接受该视频"
                    ))
                }
            }
        }
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
        static let audioLanguage = "settings.audioLanguage"
        static let allowsCellular = "settings.allowsCellular"
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let liveActivityEnabled = "settings.liveActivityEnabled"
    }
}
