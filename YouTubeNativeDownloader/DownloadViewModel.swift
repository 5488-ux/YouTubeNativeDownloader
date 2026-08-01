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
    @Published private(set) var errorText: String?
    @Published private(set) var latestFile: URL?
    @Published private(set) var savedFiles: [URL] = []

    private let resolver = VideoResolver()

    init() {
        refreshFiles()
    }

    func start() {
        guard !isBusy else { return }
        errorText = nil
        latestFile = nil
        isBusy = true
        progress = 0
        statusText = "正在本机解析 YouTube…"

        Task {
            do {
                let media = try await resolver.resolve(urlText: urlText, quality: quality, kind: kind)
                let output: URL

                switch kind {
                case .video:
                    guard let video = media.video else { throw DownloaderError.noCompatibleVideo }

                    statusText = resolutionText(video) + " · 正在下载视频"
                    let videoTransfer = DownloadTransfer()
                    let videoFile = try await videoTransfer.download(source: video) { [weak self] value in
                        Task { @MainActor in self?.progress = value * 0.82 }
                    }

                    statusText = "正在下载 AAC 音频"
                    let audioTransfer = DownloadTransfer()
                    let audioFile = try await audioTransfer.download(source: media.audio) { [weak self] value in
                        Task { @MainActor in self?.progress = 0.82 + value * 0.13 }
                    }

                    statusText = "正在本机无损合并"
                    progress = 0.97
                    output = try await MediaFileBuilder.merge(
                        videoURL: videoFile,
                        audioURL: audioFile,
                        title: media.title
                    )
                    try? FileManager.default.removeItem(at: videoFile)
                    try? FileManager.default.removeItem(at: audioFile)

                case .audio:
                    statusText = "正在下载 AAC 音频"
                    let transfer = DownloadTransfer()
                    let audioFile = try await transfer.download(source: media.audio) { [weak self] value in
                        Task { @MainActor in self?.progress = value * 0.98 }
                    }
                    output = try MediaFileBuilder.saveAudio(sourceURL: audioFile, title: media.title)
                }

                progress = 1
                statusText = "完成，文件已保存在 App 文稿目录"
                latestFile = output
                refreshFiles()
            } catch {
                errorText = error.localizedDescription
                statusText = "下载失败"
            }
            isBusy = false
        }
    }

    func cancelMessage() {
        errorText = nil
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

    private func resolutionText(_ source: MediaSource) -> String {
        guard let width = source.width, let height = source.height else { return "H.264" }
        let fps = source.fps.map { " · \($0)fps" } ?? ""
        return "\(width)×\(height)\(fps) · H.264"
    }
}
