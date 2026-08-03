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

    private var webView: WKWebView?
    private var preparationTask: Task<Void, Error>?
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var navigationID: UUID?
    private var isPrepared = false

    private override init() {
        super.init()
    }

    func mediaAccess(
        videoID: String,
        playerURL: URL,
        nChallenges: [String],
        signatureChallenges: [String]
    ) async throws -> LocalMediaAccess {
        try await prepareIfNeeded()
        guard let webView else {
            throw Self.runtimeError("本机 YouTube 运行环境没有启动")
        }

        DiagnosticLogger.shared.info(
            "开始本机生成媒体授权; videoID=\(videoID); nChallenges=\(nChallenges.count); " +
            "signatureChallenges=\(signatureChallenges.count); runtime=WebKit+BgUtils+yt-dlp-ejs"
        )

        let script = """
        const videoID = arguments.videoID;
        const playerURL = arguments.playerURL;
        const nChallenges = arguments.nChallenges;
        const signatureChallenges = arguments.signatureChallenges;

        if (!globalThis.LocalYouTubePO || !globalThis.YTDLPEJS?.default) {
            throw new Error('本机 YouTube 组件尚未加载');
        }

        const [poToken, playerResponse] = await Promise.all([
            globalThis.LocalYouTubePO.generatePoToken(videoID),
            fetch(playerURL, { credentials: 'omit', cache: 'no-store' })
        ]);
        if (!playerResponse.ok) {
            throw new Error(`播放器脚本请求失败：HTTP ${playerResponse.status}`);
        }

        const player = await playerResponse.text();
        const requests = [];
        if (nChallenges.length) requests.push({ type: 'n', challenges: nChallenges });
        if (signatureChallenges.length) requests.push({ type: 'sig', challenges: signatureChallenges });
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
        const solvedN = nChallenges.length ? result.responses[index++].data : {};
        const solvedSignatures = signatureChallenges.length ? result.responses[index++].data : {};
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
                    "videoID": videoID,
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
                "本机媒体授权成功; videoID=\(videoID); tokenBytes=\(poToken.utf8.count); " +
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

    private func resetRuntime() {
        isPrepared = false
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
}
