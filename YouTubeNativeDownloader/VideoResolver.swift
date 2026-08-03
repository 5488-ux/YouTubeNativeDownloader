import CryptoKit
import Foundation
import Security

struct MediaSource: Sendable {
    let url: URL
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
    let hlsVideo: MediaSource?
    let audio: MediaSource
}

enum DownloadKind: String, CaseIterable, Identifiable, Codable {
    case video = "视频 MP4"
    case audio = "音频 M4A"

    var id: String { rawValue }
}

enum VideoQuality: String, CaseIterable, Identifiable, Codable {
    case best = "最佳画质"
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

enum YouTubeCookieStore {
    private static let service = "cn.local.YouTubeNativeDownloader.youtube-cookie"
    private static let account = "youtube"

    static var hasCookie: Bool {
        guard let value = load() else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func save(_ rawValue: String) throws {
        let value = normalizedCookieHeader(rawValue)
        guard !value.isEmpty else {
            delete()
            return
        }

        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw keychainError(updateStatus) }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    static func normalizedCookieHeader(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let objects = object as? [[String: Any]] {
            let pairs = objects.compactMap { object -> String? in
                if let domain = object["domain"] as? String,
                   !domain.lowercased().contains("youtube.com") {
                    return nil
                }
                guard let name = object["name"] as? String,
                      let value = object["value"] as? String,
                      !name.isEmpty else { return nil }
                return "\(name)=\(value)"
            }
            if !pairs.isEmpty { return pairs.joined(separator: "; ") }
        }

        let lines = trimmed.components(separatedBy: .newlines)
        let netscapePairs = lines.compactMap { line -> String? in
            var clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.hasPrefix("#HttpOnly_") {
                clean.removeFirst("#HttpOnly_".count)
            }
            guard !clean.isEmpty, !clean.hasPrefix("#") else { return nil }
            let columns = clean.components(separatedBy: "\t")
            guard columns.count >= 7,
                  columns[0].lowercased().contains("youtube.com"),
                  !columns[5].isEmpty else { return nil }
            return "\(columns[5])=\(columns[6])"
        }
        if !netscapePairs.isEmpty { return netscapePairs.joined(separator: "; ") }

        return trimmed
            .replacingOccurrences(of: "Cookie:", with: "", options: [.caseInsensitive, .anchored])
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "; ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "Cookie 保存失败"
        return NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

final class VideoResolver {
    private struct ClientProfile {
        let name: String
        let numericName: String
        let version: String
        let userAgent: String
        let supportsCookies: Bool
        let embedURL: String?
    }

    private struct SessionContext {
        let sessionIndex: String?
        let delegatedSessionID: String?
        let userSessionID: String?
        let loggedIn: Bool
    }

    private struct Candidate {
        let source: MediaSource
        let mimeType: String
    }

    private let webUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"

    func resolve(
        urlText: String,
        quality: VideoQuality,
        kind: DownloadKind
    ) async throws -> ResolvedMedia {
        let videoID = try Self.extractVideoID(from: urlText)
        let cookie = YouTubeCookieStore.load() ?? ""
        let storedCookieValues = Self.cookieValues(cookie)
        let hasLoginCookie = storedCookieValues["LOGIN_INFO"] != nil
        let hasSIDCookie = storedCookieValues["SAPISID"] != nil
            || storedCookieValues["__Secure-1PAPISID"] != nil
            || storedCookieValues["__Secure-3PAPISID"] != nil
        let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)&bpctr=9999999999&has_verified=1")!

        DiagnosticLogger.shared.info(
            "开始本机解析 YouTube; videoID=\(videoID); cookie=\(cookie.isEmpty ? "none" : "configured"); " +
            "loginInfo=\(hasLoginCookie); sid=\(hasSIDCookie)"
        )
        if !cookie.isEmpty, !hasLoginCookie || !hasSIDCookie {
            DiagnosticLogger.shared.warning("Cookie 缺少 LOGIN_INFO 或 SAPISID 系列字段，可能不是完整的 YouTube 登录 Cookie")
        }
        var watchRequest = URLRequest(url: watchURL)
        watchRequest.timeoutInterval = 45
        applyCommonHeaders(to: &watchRequest, cookie: cookie, userAgent: webUserAgent)
        let (watchData, _) = try await requestData(watchRequest, stage: "读取 YouTube 页面")
        guard let html = String(data: watchData, encoding: .utf8) else {
            throw DownloaderError.extractionFailed("YouTube 页面编码无法识别。")
        }

        guard let apiKey = Self.capture(#""INNERTUBE_API_KEY":"([^"]+)""#, in: html) else {
            throw DownloaderError.extractionFailed("页面中没有 Innertube API Key，YouTube 可能修改了解析格式。")
        }
        let visitorData = Self.capture(#""VISITOR_DATA":"([^"]+)""#, in: html)
            .flatMap(Self.decodeJSONString)
        let webVersion = Self.capture(#""INNERTUBE_CLIENT_VERSION":"([^"]+)""#, in: html)
            ?? "2.20260731.01.00"
        let sessionContext = Self.sessionContext(from: html)

        let anonymousProfiles = [
            ClientProfile(
                name: "IOS",
                numericName: "5",
                version: "21.26.4",
                userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
                supportsCookies: false,
                embedURL: nil
            ),
            ClientProfile(
                name: "VISIONOS",
                numericName: "101",
                version: "1.02",
                userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                supportsCookies: false,
                embedURL: nil
            ),
            ClientProfile(
                name: "ANDROID_VR",
                numericName: "28",
                version: "1.65.10",
                userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                supportsCookies: false,
                embedURL: nil
            )
        ]
        let authenticatedProfiles = [
            ClientProfile(
                name: "WEB",
                numericName: "1",
                version: webVersion,
                userAgent: webUserAgent,
                supportsCookies: true,
                embedURL: nil
            ),
            ClientProfile(
                name: "WEB",
                numericName: "1",
                version: webVersion,
                userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
                supportsCookies: true,
                embedURL: nil
            ),
            ClientProfile(
                name: "WEB_EMBEDDED_PLAYER",
                numericName: "56",
                version: webVersion,
                userAgent: webUserAgent,
                supportsCookies: true,
                embedURL: "https://www.youtube.com/embed/\(videoID)"
            ),
            ClientProfile(
                name: "MWEB",
                numericName: "2",
                version: "2.20260708.05.00",
                userAgent: "Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)",
                supportsCookies: true,
                embedURL: nil
            ),
            ClientProfile(
                name: "TVHTML5",
                numericName: "7",
                version: "7.20260707.07.00",
                userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)",
                supportsCookies: true,
                embedURL: nil
            ),
            ClientProfile(
                name: "TVHTML5",
                numericName: "7",
                version: "5.20260707",
                userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
                supportsCookies: true,
                embedURL: nil
            )
        ]
        let profiles = cookie.isEmpty ? anonymousProfiles : authenticatedProfiles + anonymousProfiles

        var lastReason = "YouTube 没有返回播放格式"
        var sawCipheredFormats = false
        for profile in profiles {
            do {
                let response = try await playerResponse(
                    videoID: videoID,
                    apiKey: apiKey,
                    visitorData: visitorData,
                    cookie: cookie,
                    sessionContext: sessionContext,
                    profile: profile
                )
                let playability = response["playabilityStatus"] as? [String: Any]
                let status = playability?["status"] as? String ?? "UNKNOWN"
                let reason = playability?["reason"] as? String ?? status
                guard status == "OK" else {
                    lastReason = reason
                    DiagnosticLogger.shared.warning("本机解析客户端不可用; client=\(profile.name) \(profile.version); status=\(status); reason=\(reason)")
                    continue
                }

                let details = response["videoDetails"] as? [String: Any]
                let title = details?["title"] as? String ?? "YouTube \(videoID)"
                let streaming = response["streamingData"] as? [String: Any]
                let formats = ((streaming?["formats"] as? [[String: Any]]) ?? [])
                    + ((streaming?["adaptiveFormats"] as? [[String: Any]]) ?? [])
                let candidates = formats.compactMap {
                    makeCandidate($0, cookie: cookie, userAgent: profile.userAgent, watchURL: watchURL)
                }
                let hlsVideo = kind == .video
                    ? try await makeHLSSource(
                        streaming: streaming,
                        quality: quality,
                        cookie: cookie,
                        userAgent: profile.userAgent,
                        watchURL: watchURL
                    )
                    : nil
                sawCipheredFormats = sawCipheredFormats || formats.contains { format in
                    format["signatureCipher"] != nil || format["cipher"] != nil
                }

                let audio = selectAudio(from: candidates)
                let video = selectVideo(from: candidates, quality: quality)
                if let audio, kind == .audio || video != nil || hlsVideo != nil {
                    DiagnosticLogger.shared.info(
                        "本机解析成功; client=\(profile.name) \(profile.version); formats=\(formats.count); " +
                        "direct=\(candidates.count); hls=\(hlsVideo != nil)"
                    )
                    return ResolvedMedia(
                        title: title,
                        videoID: videoID,
                        video: kind == .video ? video : nil,
                        hlsVideo: hlsVideo,
                        audio: audio
                    )
                }
                lastReason = "没有找到可直接下载的 H.264 与 AAC 格式"
            } catch {
                lastReason = error.localizedDescription
                DiagnosticLogger.shared.error(error, stage: "本机解析客户端 \(profile.name) \(profile.version)")
            }
        }

        if cookie.isEmpty {
            throw DownloaderError.extractionFailed("YouTube 要求登录验证。请到设置粘贴 YouTube Cookie 后重试。")
        }
        if sawCipheredFormats {
            throw DownloaderError.extractionFailed("YouTube 只返回了加密媒体地址，本机解析规则需要随 App 更新。")
        }
        throw DownloaderError.extractionFailed("\(lastReason)。Cookie 可能已失效，请在设置中重新填写。")
    }

    private func playerResponse(
        videoID: String,
        apiKey: String,
        visitorData: String?,
        cookie: String,
        sessionContext: SessionContext,
        profile: ClientProfile
    ) async throws -> [String: Any] {
        var client: [String: Any] = [
            "clientName": profile.name,
            "clientVersion": profile.version,
            "hl": "en",
            "gl": "US",
            "userAgent": profile.userAgent,
            "timeZone": "UTC",
            "utcOffsetMinutes": 0
        ]
        if let visitorData { client["visitorData"] = visitorData }
        if profile.name == "IOS" {
            client["deviceMake"] = "Apple"
            client["deviceModel"] = "iPhone16,2"
            client["osName"] = "iPhone"
            client["osVersion"] = "18.6.0.22G86"
        } else if profile.name == "VISIONOS" {
            client["deviceMake"] = "Apple"
            client["deviceModel"] = "RealityDevice17,1"
            client["osName"] = "visionOS"
            client["osVersion"] = "26.5.23O471"
        } else if profile.name == "ANDROID_VR" {
            client["deviceMake"] = "Oculus"
            client["deviceModel"] = "Quest 3"
            client["androidSdkVersion"] = 32
            client["osName"] = "Android"
            client["osVersion"] = "12L"
        }

        var context: [String: Any] = ["client": client]
        if let embedURL = profile.embedURL {
            context["thirdParty"] = ["embedUrl": embedURL]
        }
        let body: [String: Any] = [
            "context": context,
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": [
                "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]
            ]
        ]
        let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(apiKey)&prettyPrint=false")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 45
        let requestCookie = profile.supportsCookies ? cookie : ""
        applyCommonHeaders(to: &request, cookie: requestCookie, userAgent: profile.userAgent)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(profile.numericName, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(profile.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if profile.supportsCookies {
            applyCookieAuthorization(to: &request, cookie: cookie, sessionContext: sessionContext)
        }

        let (data, _) = try await requestData(request, stage: "请求 Innertube \(profile.name)")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DownloaderError.extractionFailed("Innertube 返回内容无法识别。")
        }
        return object
    }

    private func requestData(
        _ request: URLRequest,
        stage: String
    ) async throws -> (Data, HTTPURLResponse) {
        let retryableCodes: Set<URLError.Code> = [
            .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
            .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed
        ]
        var lastError: Error?
        for attempt in 1...3 {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 60
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: configuration)
            do {
                let (data, response) = try await session.data(for: request)
                session.finishTasksAndInvalidate()
                guard let http = response as? HTTPURLResponse else {
                    throw DownloaderError.extractionFailed("\(stage) 没有返回 HTTP 响应。")
                }
                guard (200...299).contains(http.statusCode) else {
                    let detail = Self.responseDetail(data)
                    let responseMIMEType = http.mimeType ?? "unknown"
                    DiagnosticLogger.shared.warning(
                        "\(stage) HTTP=\(http.statusCode); mime=\(responseMIMEType); body=\(detail)"
                    )
                    if attempt < 3, [408, 425, 429, 500, 502, 503, 504].contains(http.statusCode) {
                        DiagnosticLogger.shared.warning("\(stage) HTTP=\(http.statusCode)，自动重试 \(attempt)/2")
                        try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                        continue
                    }
                    throw DownloaderError.extractionFailed("\(stage) 返回 HTTP \(http.statusCode)：\(detail)")
                }
                return (data, http)
            } catch let error as URLError {
                session.invalidateAndCancel()
                lastError = error
                if attempt < 3, retryableCodes.contains(error.code) {
                    DiagnosticLogger.shared.warning("\(stage) 连接中断，自动重试; code=\(error.code.rawValue); attempt=\(attempt)/2")
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    continue
                }
                throw DownloaderError.extractionFailed("\(stage) 失败：\(error.localizedDescription)")
            } catch {
                session.invalidateAndCancel()
                throw error
            }
        }
        throw lastError ?? DownloaderError.extractionFailed("\(stage) 未完成。")
    }

    private func makeCandidate(
        _ format: [String: Any],
        cookie: String,
        userAgent: String,
        watchURL: URL
    ) -> Candidate? {
        guard let mimeType = format["mimeType"] as? String,
              let mediaURL = Self.mediaURL(from: format) else { return nil }
        let codec = Self.codec(from: mimeType) ?? "unknown"
        let contentLength = Self.int64(format["contentLength"])
        let headers: [String: String] = [
            "User-Agent": userAgent,
            "Referer": watchURL.absoluteString,
            "Origin": "https://www.youtube.com",
            "Cookie": cookie
        ].filter { !$0.value.isEmpty }
        return Candidate(
            source: MediaSource(
                url: mediaURL,
                httpHeaders: headers,
                contentLength: contentLength,
                codec: codec,
                width: Self.int(format["width"]),
                height: Self.int(format["height"]),
                fps: Self.int(format["fps"]),
                bitrate: Self.int(format["bitrate"])
            ),
            mimeType: mimeType
        )
    }

    private func makeHLSSource(
        streaming: [String: Any]?,
        quality: VideoQuality,
        cookie: String,
        userAgent: String,
        watchURL: URL
    ) async throws -> MediaSource? {
        guard let value = streaming?["hlsManifestUrl"] as? String,
              let masterURL = URL(string: value) else { return nil }
        let headers: [String: String] = [
            "User-Agent": userAgent,
            "Referer": watchURL.absoluteString,
            "Origin": "https://www.youtube.com",
            "Cookie": cookie
        ].filter { !$0.value.isEmpty }
        var request = URLRequest(url: masterURL)
        request.timeoutInterval = 30
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, _) = try await requestData(request, stage: "读取 HLS 清单")
        guard let playlist = String(data: data, encoding: .utf8) else { return nil }

        struct Variant {
            let url: URL
            let width: Int?
            let height: Int?
            let bandwidth: Int
        }
        let lines = playlist.components(separatedBy: .newlines)
        var variants: [Variant] = []
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-STREAM-INF:"), index + 1 < lines.count else { continue }
            let attributes = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            guard attributes.range(of: "avc1", options: .caseInsensitive) != nil else { continue }
            let next = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !next.isEmpty, !next.hasPrefix("#"), let url = URL(string: next, relativeTo: masterURL)?.absoluteURL else { continue }
            let resolution = Self.capture(#"RESOLUTION=([0-9]+x[0-9]+)"#, in: attributes)?
                .split(separator: "x")
                .compactMap { Int($0) }
            let bandwidth = Self.capture(#"BANDWIDTH=([0-9]+)"#, in: attributes).flatMap(Int.init) ?? 0
            variants.append(Variant(
                url: url,
                width: resolution?.count == 2 ? resolution?[0] : nil,
                height: resolution?.count == 2 ? resolution?[1] : nil,
                bandwidth: bandwidth
            ))
        }
        let allowed = variants.filter { variant in
            guard let limit = quality.maximumHeight else { return true }
            return (variant.height ?? 0) <= limit
        }
        guard let selected = allowed.max(by: { left, right in
            if (left.height ?? 0) != (right.height ?? 0) { return (left.height ?? 0) < (right.height ?? 0) }
            return left.bandwidth < right.bandwidth
        }) ?? variants.max(by: { $0.bandwidth < $1.bandwidth }) else { return nil }
        DiagnosticLogger.shared.info(
            "选择 HLS 变体; resolution=\(selected.width ?? 0)x\(selected.height ?? 0); bandwidth=\(selected.bandwidth)"
        )
        return MediaSource(
            url: selected.url,
            httpHeaders: headers,
            contentLength: nil,
            codec: "avc1+hls",
            width: selected.width,
            height: selected.height,
            fps: nil,
            bitrate: selected.bandwidth
        )
    }

    private func selectVideo(from candidates: [Candidate], quality: VideoQuality) -> MediaSource? {
        candidates
            .filter {
                $0.mimeType.contains("video/mp4") &&
                $0.mimeType.contains("avc1") &&
                (quality.maximumHeight == nil || ($0.source.height ?? 0) <= quality.maximumHeight!)
            }
            .sorted { left, right in
                let leftScore = (left.source.height ?? 0, left.source.fps ?? 0, left.source.bitrate ?? 0)
                let rightScore = (right.source.height ?? 0, right.source.fps ?? 0, right.source.bitrate ?? 0)
                if leftScore.0 != rightScore.0 { return leftScore.0 > rightScore.0 }
                if leftScore.1 != rightScore.1 { return leftScore.1 > rightScore.1 }
                return leftScore.2 > rightScore.2
            }
            .first?.source
    }

    private func selectAudio(from candidates: [Candidate]) -> MediaSource? {
        candidates
            .filter { $0.mimeType.contains("audio/mp4") && $0.mimeType.contains("mp4a") }
            .max { ($0.source.bitrate ?? 0) < ($1.source.bitrate ?? 0) }?
            .source
    }

    private func applyCommonHeaders(to request: inout URLRequest, cookie: String, userAgent: String) {
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "X-Origin")
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
    }

    private func applyCookieAuthorization(
        to request: inout URLRequest,
        cookie: String,
        sessionContext: SessionContext
    ) {
        guard !cookie.isEmpty else { return }
        let values = Self.cookieValues(cookie)
        let primarySID = values["SAPISID"] ?? values["__Secure-3PAPISID"]
        let sidValues: [(String, String?)] = [
            ("SAPISIDHASH", primarySID),
            ("SAPISID1PHASH", values["__Secure-1PAPISID"]),
            ("SAPISID3PHASH", values["__Secure-3PAPISID"])
        ]
        let timestamp = Int(Date().timeIntervalSince1970)
        let authorizations = sidValues.compactMap { scheme, sid -> String? in
            guard let sid, !sid.isEmpty else { return nil }
            let prefix = sessionContext.userSessionID.map { "\($0) " } ?? ""
            let input = "\(prefix)\(timestamp) \(sid) https://www.youtube.com"
            let digest = Insecure.SHA1.hash(data: Data(input.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let suffix = sessionContext.userSessionID.map { "_u\($0)" } ?? ""
            return "\(scheme) \(timestamp)_\(digest)\(suffix)"
        }
        if !authorizations.isEmpty {
            request.setValue(authorizations.joined(separator: " "), forHTTPHeaderField: "Authorization")
            request.setValue("https://www.youtube.com", forHTTPHeaderField: "X-Origin")
        }
        if let delegatedSessionID = sessionContext.delegatedSessionID {
            request.setValue(delegatedSessionID, forHTTPHeaderField: "X-Goog-PageId")
        }
        if sessionContext.delegatedSessionID != nil || sessionContext.sessionIndex != nil {
            request.setValue(sessionContext.sessionIndex ?? "0", forHTTPHeaderField: "X-Goog-AuthUser")
        }
        if sessionContext.loggedIn {
            request.setValue("true", forHTTPHeaderField: "X-Youtube-Bootstrap-Logged-In")
        }
    }

    private static func mediaURL(from format: [String: Any]) -> URL? {
        if let value = format["url"] as? String { return URL(string: value) }
        guard let cipher = (format["signatureCipher"] as? String) ?? (format["cipher"] as? String),
              let components = URLComponents(string: "https://local.invalid/?\(cipher)"),
              let urlValue = components.queryItems?.first(where: { $0.name == "url" })?.value,
              var mediaComponents = URLComponents(string: urlValue) else { return nil }
        let signature = components.queryItems?.first(where: { ["sig", "signature"].contains($0.name) })?.value
        if let signature {
            let parameter = components.queryItems?.first(where: { $0.name == "sp" })?.value ?? "signature"
            var items = mediaComponents.queryItems ?? []
            items.append(URLQueryItem(name: parameter, value: signature))
            mediaComponents.queryItems = items
            return mediaComponents.url
        }
        return nil
    }

    private static func codec(from mimeType: String) -> String? {
        guard let range = mimeType.range(of: "codecs=\"") else { return nil }
        let suffix = mimeType[range.upperBound...]
        guard let end = suffix.firstIndex(of: "\"") else { return nil }
        return String(suffix[..<end]).components(separatedBy: ",").first
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func decodeJSONString(_ value: String) -> String? {
        let wrapped = "\"\(value)\""
        return try? JSONDecoder().decode(String.self, from: Data(wrapped.utf8))
    }

    private static func sessionContext(from html: String) -> SessionContext {
        let sessionIndex = capture(#""SESSION_INDEX":"([0-9]+)""#, in: html)
            ?? capture(#""SESSION_INDEX":([0-9]+)"#, in: html)
        let explicitDelegatedID = capture(#""DELEGATED_SESSION_ID":"([^"]+)""#, in: html)
            .flatMap(decodeJSONString)
        let dataSyncID = capture(#""DATASYNC_ID":"([^"]+)""#, in: html)
            .flatMap(decodeJSONString)
        var delegatedID = explicitDelegatedID
        var userSessionID: String?
        if let dataSyncID {
            let parts = dataSyncID.components(separatedBy: "||")
            if parts.count > 1, !parts[1].isEmpty {
                if delegatedID == nil, !parts[0].isEmpty { delegatedID = parts[0] }
                userSessionID = parts[1]
            } else if !parts[0].isEmpty {
                userSessionID = parts[0]
            }
        }
        let loggedIn = html.range(of: #""LOGGED_IN":true"#) != nil
        return SessionContext(
            sessionIndex: sessionIndex,
            delegatedSessionID: delegatedID,
            userSessionID: userSessionID,
            loggedIn: loggedIn
        )
    }

    private static func responseDetail(_ data: Data) -> String {
        if let decoded = try? JSONSerialization.jsonObject(with: data),
           let object = decoded as? [String: Any],
           let error = object["error"] as? [String: Any] {
            let status = error["status"] as? String
            let message = error["message"] as? String
            let joined = [status, message].compactMap { $0 }.joined(separator: ": ")
            if !joined.isEmpty { return String(joined.prefix(300)) }
        }
        let text = String(data: data.prefix(600), encoding: .utf8) ?? "non-text response"
        return String(
            text.replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(300)
        )
    }

    private static func cookieValues(_ cookie: String) -> [String: String] {
        var values: [String: String] = [:]
        for part in cookie.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            values[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1]
        }
        return values
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
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
