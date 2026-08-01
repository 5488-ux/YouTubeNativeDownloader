import Foundation

struct MediaSource: Sendable {
    let url: URL
    let fallbackURL: URL?
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
    case video = "视频 MOV"
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
    let contentLength: Int64?
    let codec: String?
    let width: Int?
    let height: Int?
    let fps: Int?
    let bitrate: Int?

    enum CodingKeys: String, CodingKey {
        case url, codec, width, height, fps, bitrate
        case fallbackURL = "fallback_url"
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
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(ResolveRequest(
            url: urlText.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind.apiValue,
            quality: quality.apiValue
        ))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 75
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .timedOut {
                throw DownloaderError.resolverUnavailable("解析服务器响应超时，请重试。")
            }
            throw DownloaderError.resolverUnavailable("无法连接解析服务器：\(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw DownloaderError.resolverUnavailable("解析服务器没有返回有效响应。")
        }

        let decoded: ResolveResponse
        do {
            decoded = try JSONDecoder().decode(ResolveResponse.self, from: data)
        } catch {
            throw DownloaderError.resolverUnavailable("解析服务器返回了无法识别的数据（HTTP \(http.statusCode)）。")
        }

        guard (200...299).contains(http.statusCode), decoded.ok else {
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

    private func makeSource(_ source: SourceResponse) -> MediaSource? {
        guard let url = URL(string: source.url) else { return nil }
        return MediaSource(
            url: url,
            fallbackURL: source.fallbackURL.flatMap(URL.init(string:)),
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
