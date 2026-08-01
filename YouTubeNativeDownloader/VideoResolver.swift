import Foundation
import YouTubeKit

struct MediaSource: Sendable {
    let url: URL
    let contentLength: Int?
    let codec: String
    let width: Int?
    let height: Int?
    let fps: Int?
    let bitrate: Int?
}

struct ResolvedMedia: Sendable {
    let title: String
    let videoID: String
    let video: MediaSource?
    let audio: MediaSource
}

enum DownloadKind: String, CaseIterable, Identifiable {
    case video = "视频 MP4"
    case audio = "音频 M4A"

    var id: String { rawValue }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case best = "最佳兼容"
    case p1080 = "1080P"
    case p720 = "720P"
    case p480 = "480P"

    var id: String { rawValue }

    var maximumHeight: Int? {
        switch self {
        case .best: return nil
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        }
    }
}

final class VideoResolver {
    private let model: YouTubeModel

    init() {
        let model = YouTubeModel()
        model.selectedLocale = "en-US"
        self.model = model
    }

    func resolve(urlText: String, quality: VideoQuality, kind: DownloadKind) async throws -> ResolvedMedia {
        let videoID = try Self.extractVideoID(from: urlText)
        try await verifyYouTubeConnection()
        let video = YTVideo(videoId: videoID)
        let response = try await fetchDownloadResponse(for: video)

        let audioCandidates = response.downloadFormats
            .compactMap { $0 as? AudioOnlyFormat }
            .filter { format in
                format.url != nil &&
                format.codec?.lowercased().contains("mp4a") == true &&
                format.isDrc == false
            }
            .sorted { lhs, rhs in
                let lhsDefault = lhs.formatLocaleInfos?.isDefaultAudioFormat ?? true
                let rhsDefault = rhs.formatLocaleInfos?.isDefaultAudioFormat ?? true
                if lhsDefault != rhsDefault { return lhsDefault }
                return (lhs.bitrate ?? 0) > (rhs.bitrate ?? 0)
            }

        guard let audioFormat = audioCandidates.first, let audioURL = audioFormat.url else {
            throw DownloaderError.noCompatibleAudio
        }

        let audio = MediaSource(
            url: audioURL,
            contentLength: audioFormat.contentLength,
            codec: audioFormat.codec ?? "mp4a",
            width: nil,
            height: nil,
            fps: nil,
            bitrate: audioFormat.bitrate
        )

        var selectedVideo: MediaSource?
        if kind == .video {
            let maximumHeight = quality.maximumHeight ?? Int.max
            let videoCandidates = response.downloadFormats
                .compactMap { $0 as? VideoDownloadFormat }
                .filter { format in
                    format.url != nil &&
                    format.codec?.lowercased().contains("avc1") == true &&
                    (format.height ?? 0) <= maximumHeight
                }
                .sorted { lhs, rhs in
                    if (lhs.height ?? 0) != (rhs.height ?? 0) {
                        return (lhs.height ?? 0) > (rhs.height ?? 0)
                    }
                    if (lhs.fps ?? 0) != (rhs.fps ?? 0) {
                        return (lhs.fps ?? 0) > (rhs.fps ?? 0)
                    }
                    return (lhs.bitrate ?? 0) > (rhs.bitrate ?? 0)
                }

            guard let videoFormat = videoCandidates.first, let videoURL = videoFormat.url else {
                throw DownloaderError.noCompatibleVideo
            }

            selectedVideo = MediaSource(
                url: videoURL,
                contentLength: videoFormat.contentLength,
                codec: videoFormat.codec ?? "avc1",
                width: videoFormat.width,
                height: videoFormat.height,
                fps: videoFormat.fps,
                bitrate: videoFormat.bitrate
            )
        }

        return ResolvedMedia(
            title: response.videoInfos.title ?? "YouTube-\(videoID)",
            videoID: videoID,
            video: selectedVideo,
            audio: audio
        )
    }

    private func fetchDownloadResponse(for video: YTVideo) async throws -> VideoInfosWithDownloadFormatsResponse {
        var lastError: Error?

        for locale in ["en-US", "zh-CN"] {
            model.selectedLocale = locale

            do {
                let playerResponse = try await video.fetchStreamingInfosThrowing(
                    youtubeModel: model,
                    useCookies: false
                )

                guard let player = playerResponse.player else {
                    throw DownloaderError.extractionFailed("YouTube 没有返回播放器脚本。")
                }

                var downloadResponse = try await video.fetchStreamingInfosWithDownloadFormatsThrowing(
                    youtubeModel: model,
                    useCookies: false
                )
                try downloadResponse.deciphersURLs(player: player)
                return downloadResponse
            } catch {
                if let urlError = Self.findURLError(in: error) {
                    throw DownloaderError.youtubeNetworkUnavailable(
                        Self.networkMessage(for: urlError)
                    )
                }
                lastError = error
                try? PlayerProcessing.PlayersCache.clearCache()
            }
        }

        if let extractionError = lastError as? ResponseExtractionError {
            throw DownloaderError.extractionFailed(extractionError.stepDescription)
        }

        throw DownloaderError.extractionFailed(
            lastError.map { String(describing: $0) } ?? "未知解析错误"
        )
    }

    private func verifyYouTubeConnection() async throws {
        guard let url = URL(string: "https://www.youtube.com/generate_204") else {
            throw DownloaderError.youtubeNetworkUnavailable("YouTube 连通性检查地址无效。")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (_, response) = try await session.data(for: request)
            guard response is HTTPURLResponse else {
                throw DownloaderError.youtubeNetworkUnavailable("当前网络没有收到 YouTube 的有效响应。")
            }
        } catch let error as DownloaderError {
            throw error
        } catch {
            if let urlError = Self.findURLError(in: error) {
                throw DownloaderError.youtubeNetworkUnavailable(
                    Self.networkMessage(for: urlError)
                )
            }
            throw DownloaderError.youtubeNetworkUnavailable("当前网络无法连接 YouTube。")
        }
    }

    private static func findURLError(in error: Error) -> URLError? {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return URLError(URLError.Code(rawValue: nsError.code))
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain {
            return URLError(URLError.Code(rawValue: underlying.code))
        }

        return nil
    }

    private static func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "连接 YouTube 超时。请先确认 Safari 能打开 YouTube，或开启可访问 YouTube 的 VPN/代理。"
        case .notConnectedToInternet:
            return "手机当前没有可用网络，请检查 Wi-Fi 或蜂窝数据。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "当前网络无法连接 YouTube，请更换网络或开启可访问 YouTube 的 VPN/代理。"
        case .networkConnectionLost:
            return "连接 YouTube 时网络中断，请检查 VPN/代理后重试。"
        default:
            return "当前网络无法访问 YouTube（网络错误 \(error.code.rawValue)）。"
        }
    }

    static func extractVideoID(from text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
            return trimmed
        }

        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased() else {
            throw DownloaderError.invalidURL
        }

        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            let id = components.path.split(separator: "/").first.map(String.init) ?? ""
            guard id.count == 11 else { throw DownloaderError.invalidURL }
            return id
        }

        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else {
            throw DownloaderError.invalidURL
        }

        if let id = components.queryItems?.first(where: { $0.name == "v" })?.value, id.count == 11 {
            return id
        }

        let parts = components.path.split(separator: "/").map(String.init)
        if let marker = parts.firstIndex(where: { ["shorts", "embed", "live"].contains($0) }),
           parts.indices.contains(marker + 1),
           parts[marker + 1].count == 11 {
            return parts[marker + 1]
        }

        throw DownloaderError.invalidURL
    }
}
