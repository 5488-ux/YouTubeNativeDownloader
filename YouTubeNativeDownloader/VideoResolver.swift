import Foundation

struct MediaSource: Sendable {
    let url: URL
    let fallbackURL: URL?
    let httpHeaders: [String: String]
    let contentLength: Int64?
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

enum DownloadKind: String, CaseIterable, Identifiable, Codable {
    case video = "视频 MP4"
    case audio = "音频 M4A"

    var id: String { rawValue }
    var apiValue: String { self == .video ? "video" : "audio" }
}

enum VideoQuality: String, CaseIterable, Identifiable, Codable {
    case best = "最佳画质"
    case p1080 = "1080P"
    case p720 = "720P"
    case p480 = "480P"

    var id: String { rawValue }

    var apiValue: String {
        switch self {
        case .best: return "best"
        case .p1080: return "1080"
        case .p720: return "720"
        case .p480: return "480"
        }
    }
}

private struct ResolveRequest: Encodable {
    let url: String
    let kind: String
    let quality: String
}

private struct ResolveResponse: Decodable {
    let ok: Bool
    let message: String?
    let title: String?
    let videoID: String?
    let video: SourceResponse?
    let audio: SourceResponse?

    enum CodingKeys: String, CodingKey {
        case ok, message, title, video, audio
        case videoID = "video_id"
    }
}

private struct SourceResponse: Decodable {
    let url: String
    let fallbackURL: String?
    let httpHeaders: [String: String]?
    let contentLength: Int64?
    let codec: String?
    let width: Int?
    let height: Int?
    let fps: Int?
    let bitrate: Int?

    enum CodingKeys: String, CodingKey {
        case url, codec, width, height, fps, bitrate
        case fallbackURL = "fallback_url"
        case httpHeaders = "http_headers"
        case contentLength = "content_length"
    }
}

final class VideoResolver {
    func resolve(
        urlText: String,
        quality: VideoQuality,
        kind: DownloadKind,
        endpoint: URL
    ) async throws -> ResolvedMedia {
        _ = try Self.extractVideoID(from: urlText)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("YouTubeNativeDownloader/5.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(ResolveRequest(
            url: urlText.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind.apiValue,
            quality: quality.apiValue
        ))
        DiagnosticLogger.shared.info("解析请求已创建; timeout=75s; maxAttempts=3")

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.timeoutIntervalForRequest = 75
            configuration.timeoutIntervalForResource = 90
            configuration.waitsForConnectivity = true
            configuration.httpMaximumConnectionsPerHost = 1
            let session = URLSession(configuration: configuration)
            DiagnosticLogger.shared.info("开始解析请求; attempt=\(attempt)/\(maxAttempts)")

            do {
                let (data, response) = try await session.data(for: request)
                session.finishTasksAndInvalidate()

                guard let http = response as? HTTPURLResponse else {
                    DiagnosticLogger.shared.warning("解析响应不是 HTTPURLResponse; attempt=\(attempt)")
                    throw DownloaderError.resolverUnavailable("解析服务器没有返回有效响应。")
                }
                DiagnosticLogger.shared.info(
                    "解析响应; attempt=\(attempt); HTTP=\(http.statusCode); bytes=\(data.count); " +
                    "mime=\(http.mimeType ?? "unknown")"
                )

                if Self.isRetryableHTTPStatus(http.statusCode) {
                    if attempt < maxAttempts {
                        DiagnosticLogger.shared.warning(
                            "解析服务器暂时异常，自动重试; HTTP=\(http.statusCode); nextAttempt=\(attempt + 1)"
                        )
                        try await Self.waitBeforeRetry(attempt: attempt)
                        continue
                    }
                    throw DownloaderError.resolverUnavailable(
                        "解析服务器暂时不可用（HTTP \(http.statusCode)），已自动重试 \(maxAttempts) 次。"
                    )
                }

                return try decodeResolvedMedia(data: data, http: http, kind: kind)
            } catch let error as URLError {
                session.invalidateAndCancel()
                DiagnosticLogger.shared.error(error, stage: "解析网络请求 attempt=\(attempt)/\(maxAttempts)")
                if Self.isRetryableNetworkError(error), attempt < maxAttempts {
                    DiagnosticLogger.shared.warning(
                        "解析连接中断，自动重试; code=\(error.code.rawValue); nextAttempt=\(attempt + 1)"
                    )
                    try await Self.waitBeforeRetry(attempt: attempt)
                    continue
                }
                if error.code == .timedOut {
                    throw DownloaderError.resolverUnavailable(
                        "解析服务器响应超时，已自动重试 \(attempt) 次。"
                    )
                }
                throw DownloaderError.resolverUnavailable(
                    "无法连接解析服务器（已尝试 \(attempt) 次）：\(error.localizedDescription)"
                )
            } catch {
                session.invalidateAndCancel()
                throw error
            }
        }

        throw DownloaderError.resolverUnavailable("解析请求未能完成。")
    }

    private func decodeResolvedMedia(
        data: Data,
        http: HTTPURLResponse,
        kind: DownloadKind
    ) throws -> ResolvedMedia {
        let decoded: ResolveResponse
        do {
            decoded = try JSONDecoder().decode(ResolveResponse.self, from: data)
        } catch {
            DiagnosticLogger.shared.error(error, stage: "解析 JSON 解码")
            throw DownloaderError.resolverUnavailable("解析服务器返回了无法识别的数据（HTTP \(http.statusCode)）。")
        }

        guard (200...299).contains(http.statusCode), decoded.ok else {
            DiagnosticLogger.shared.warning("解析业务失败; HTTP=\(http.statusCode); message=\(decoded.message ?? "none")")
            throw DownloaderError.extractionFailed(decoded.message ?? "服务器解析失败（HTTP \(http.statusCode)）")
        }
        guard let title = decoded.title,
              let videoID = decoded.videoID,
              let audioResponse = decoded.audio,
              let audio = makeSource(audioResponse) else {
            throw DownloaderError.extractionFailed("解析结果缺少音频地址。")
        }

        let video = decoded.video.flatMap(makeSource)
        if kind == .video, video == nil {
            throw DownloaderError.noCompatibleVideo
        }

        return ResolvedMedia(
            title: title,
            videoID: videoID,
            video: video,
            audio: audio
        )
    }

    private static func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 ||
        statusCode == 425 ||
        statusCode == 429 ||
        statusCode == 500 ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504 ||
        (520...524).contains(statusCode)
    }

    private static func isRetryableNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost,
             .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .secureConnectionFailed,
             .internationalRoamingOff,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static func waitBeforeRetry(attempt: Int) async throws {
        let delay = UInt64(attempt) * 1_000_000_000
        try await Task.sleep(nanoseconds: delay)
    }

    private func makeSource(_ source: SourceResponse) -> MediaSource? {
        guard let url = URL(string: source.url) else { return nil }
        return MediaSource(
            url: url,
            fallbackURL: source.fallbackURL.flatMap(URL.init(string:)),
            httpHeaders: source.httpHeaders ?? [:],
            contentLength: source.contentLength,
            codec: source.codec ?? "unknown",
            width: source.width,
            height: source.height,
            fps: source.fps,
            bitrate: source.bitrate
        )
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
           parts.indices.contains(marker + 1), parts[marker + 1].count == 11 {
            return parts[marker + 1]
        }
        throw DownloaderError.invalidURL
    }
}
