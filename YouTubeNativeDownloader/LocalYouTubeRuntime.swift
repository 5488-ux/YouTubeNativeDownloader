import Foundation
import WebKit

struct LocalMediaAccess: Sendable {
    let poToken: String
    let solvedN: [String: String]
    let solvedSignatures: [String: String]
}

@MainActor
final class LocalYouTubeRuntime: NSObject, WKNavigationDelegate {
    static let shared = LocalYouTubeRuntime()
    private static let webUserAgent = "Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)"

    private var webView: WKWebView?
    private var preparationTask: Task<Void, Error>?
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var navigationID: UUID?
    private var isPrepared = false
    private var installedCookieHeader: String?

    private override init() {
        super.init()
    }

    func mediaAccess(
        contentBinding: String,
        playerURL: URL,
        nChallenges: [String],
        signatureChallenges: [String],
        cookieHeader: String = ""
    ) async throws -> LocalMediaAccess {
        try await prepareIfNeeded()
        guard let webView else {
            throw Self.runtimeError("本机 YouTube 运行环境没有启动")
        }
        try await installCookies(cookieHeader, in: webView.configuration.websiteDataStore.httpCookieStore)

        DiagnosticLogger.shared.info(
            "开始本机生成媒体授权; bindingBytes=\(contentBinding.utf8.count); nChallenges=\(nChallenges.count); " +
            "signatureChallenges=\(signatureChallenges.count); runtime=WebKit+BgUtils+yt-dlp-ejs"
        )

        let script = """
        const contentBinding = arguments.contentBinding;
        const playerURL = arguments.playerURL;
        const nChallenges = arguments.nChallenges;
        const signatureChallenges = arguments.signatureChallenges;

        if (!globalThis.LocalYouTubePO || !globalThis.YTDLPEJS?.default) {
            throw new Error('本机 YouTube 组件尚未加载');
        }

        const poTokenPromise = globalThis.LocalYouTubePO.generatePoToken(contentBinding);
        const requests = [];
        if (nChallenges.length) requests.push({ type: 'n', challenges: nChallenges });
        if (signatureChallenges.length) requests.push({ type: 'sig', challenges: signatureChallenges });
        let solvedN = {};
        let solvedSignatures = {};
        if (requests.length) {
            const playerResponse = await fetch(playerURL, { credentials: 'omit', cache: 'no-store' });
            if (!playerResponse.ok) {
                throw new Error(`播放器脚本请求失败：HTTP ${playerResponse.status}`);
            }
            const player = await playerResponse.text();
            const result = globalThis.YTDLPEJS.default({
                type: 'player',
                player,
                requests,
                output_preprocessed: false
            });
            if (result?.type !== 'result' || result.responses?.some(item => item.type !== 'result')) {
                const failed = result?.responses?.find(item => item.type !== 'result');
                throw new Error(failed?.error || 'yt-dlp EJS 未能解开播放器挑战');
            }
            let index = 0;
            solvedN = nChallenges.length ? result.responses[index++].data : {};
            solvedSignatures = signatureChallenges.length ? result.responses[index++].data : {};
        }
        const poToken = await poTokenPromise;
        if (!poToken || nChallenges.some(value => !solvedN[value]) ||
            signatureChallenges.some(value => !solvedSignatures[value])) {
            throw new Error('本机媒体授权结果不完整');
        }
        return { po_token: poToken, solved_n: solvedN, solved_signatures: solvedSignatures };
        """

        do {
            let value = try await webView.callAsyncJavaScript(
                script,
                arguments: [
                    "contentBinding": contentBinding,
                    "playerURL": playerURL.absoluteString,
                    "nChallenges": nChallenges,
                    "signatureChallenges": signatureChallenges
                ],
                in: nil,
                contentWorld: .page
            )
            guard let dictionary = value as? [String: Any],
                  let poToken = dictionary["po_token"] as? String, !poToken.isEmpty,
                  let solvedN = Self.stringDictionary(dictionary["solved_n"]),
                  let solvedSignatures = Self.stringDictionary(dictionary["solved_signatures"]),
                  solvedN.count == nChallenges.count,
                  solvedSignatures.count == signatureChallenges.count else {
                throw Self.runtimeError("本机媒体授权返回格式错误")
            }
            DiagnosticLogger.shared.info(
                "本机媒体授权成功; tokenBytes=\(poToken.utf8.count); " +
                "solvedN=\(solvedN.count); solvedSignatures=\(solvedSignatures.count)"
            )
            return LocalMediaAccess(
                poToken: poToken,
                solvedN: solvedN,
                solvedSignatures: solvedSignatures
            )
        } catch {
            DiagnosticLogger.shared.error(error, stage: "本机处理 PO Token 与 n 挑战")
            resetRuntime()
            throw Self.runtimeError("本机 YouTube 解析组件运行失败：\(error.localizedDescription)", underlying: error)
        }
    }

    func playerResponse(
        endpoint: URL,
        body: [String: Any],
        headers: [String: String],
        cookieHeader: String
    ) async throws -> Data {
        try await prepareIfNeeded()
        guard let webView else {
            throw Self.runtimeError("本机 YouTube 运行环境没有启动")
        }

        try await installCookies(cookieHeader, in: webView.configuration.websiteDataStore.httpCookieStore)
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        guard let bodyText = String(data: bodyData, encoding: .utf8) else {
            throw Self.runtimeError("Innertube 请求 JSON 编码失败")
        }

        let script = """
        const response = await fetch(arguments.endpoint, {
            method: 'POST',
            headers: arguments.headers,
            body: arguments.body,
            credentials: 'include',
            cache: 'no-store'
        });
        return { status: response.status, text: await response.text() };
        """

        do {
            let value = try await webView.callAsyncJavaScript(
                script,
                arguments: [
                    "endpoint": endpoint.absoluteString,
                    "headers": headers,
                    "body": bodyText
                ],
                in: nil,
                contentWorld: .page
            )
            guard let result = value as? [String: Any],
                  let status = (result["status"] as? NSNumber)?.intValue,
                  let text = result["text"] as? String,
                  let data = text.data(using: .utf8) else {
                throw Self.runtimeError("WebKit Innertube 返回格式错误")
            }
            DiagnosticLogger.shared.info("WebKit Innertube 响应; HTTP=\(status); bytes=\(data.count)")
            guard (200...299).contains(status) else {
                throw Self.runtimeError("WebKit Innertube 返回 HTTP \(status)：\(String(text.prefix(500)))")
            }
            return data
        } catch {
            DiagnosticLogger.shared.error(error, stage: "WebKit 请求 Innertube Player")
            throw error
        }
    }

    private func prepareIfNeeded() async throws {
        if isPrepared, webView != nil { return }
        if let preparationTask {
            return try await preparationTask.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { throw Self.runtimeError("本机 YouTube 运行环境已释放") }
            try await self.prepare()
        }
        preparationTask = task
        do {
            try await task.value
            preparationTask = nil
        } catch {
            preparationTask = nil
            resetRuntime()
            throw error
        }
    }

    private func prepare() async throws {
        DiagnosticLogger.shared.info("启动本机 YouTube 解析组件; server=false; cookieUpload=false")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.webUserAgent
        webView.navigationDelegate = self
        self.webView = webView

        var request = URLRequest(url: URL(string: "https://www.youtube.com/robots.txt")!)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let id = UUID()
        navigationID = id

        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation = continuation
            webView.load(request)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, self.navigationID == id else { return }
                self.finishNavigation(.failure(Self.runtimeError("连接 YouTube 初始化本机组件超时")))
            }
        }

        let ejs = try bundledScript(named: "yt-ejs.bundle")
        let bgUtils = try bundledScript(named: "bgutils.bundle")
        _ = try await webView.evaluateJavaScript(ejs)
        _ = try await webView.evaluateJavaScript(bgUtils)

        let ready = try await webView.evaluateJavaScript(
            "Boolean(globalThis.YTDLPEJS?.default && globalThis.LocalYouTubePO?.generatePoToken)"
        ) as? Bool
        guard ready == true else {
            throw Self.runtimeError("本机 YouTube JavaScript 组件加载不完整")
        }

        isPrepared = true
        DiagnosticLogger.shared.info("本机 YouTube 解析组件就绪; yt-dlp-ejs=true; BgUtils=true")
    }

    private func bundledScript(named name: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              !source.isEmpty else {
            throw Self.runtimeError("IPA 缺少本机组件：\(name).js")
        }
        return source
    }

    private func installCookies(_ header: String, in store: WKHTTPCookieStore) async throws {
        if installedCookieHeader == header { return }
        let existingCookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        for cookie in existingCookies where cookie.domain.lowercased().contains("youtube.com") {
            store.delete(cookie)
        }

        let cookies = Self.cookies(from: header)
        for cookie in cookies {
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
        if !cookies.isEmpty {
            DiagnosticLogger.shared.info("Cookie 已注入本机 WebKit 会话; count=\(cookies.count)")
        } else {
            DiagnosticLogger.shared.info("本机 WebKit 会话已清除 YouTube Cookie")
        }
        installedCookieHeader = header
    }

    private func resetRuntime() {
        isPrepared = false
        installedCookieHeader = nil
        navigationID = nil
        if let navigationContinuation {
            self.navigationContinuation = nil
            navigationContinuation.resume(throwing: Self.runtimeError("本机 YouTube 运行环境已重置"))
        }
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        navigationID = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(error))
    }

    private static func runtimeError(_ message: String, underlying: Error? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let underlying { userInfo[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: "LocalYouTubeRuntime", code: 1, userInfo: userInfo)
    }

    private static func stringDictionary(_ value: Any?) -> [String: String]? {
        guard let dictionary = value as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            guard let text = value as? String else { return nil }
            result[key] = text
        }
        return result
    }

    private static func cookies(from header: String) -> [HTTPCookie] {
        header.split(separator: ";").compactMap { part in
            let pair = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let name = String(pair[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(pair[pair.index(after: separator)...])
            guard !name.isEmpty else { return nil }
            return HTTPCookie(properties: [
                .domain: ".youtube.com",
                .path: "/",
                .name: name,
                .value: value,
                .secure: "TRUE"
            ])
        }
    }
}
