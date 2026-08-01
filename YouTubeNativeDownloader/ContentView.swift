import SwiftUI
import UIKit
import WebKit

struct ContentView: View {
    @StateObject private var model = DownloadViewModel()
    @State private var shareItem: ShareItem?
    @State private var showingCookieSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.91, green: 0.97, blue: 1.0), Color(red: 0.83, green: 0.89, blue: 1.0)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        header
                        composer
                        progressCard
                        filesCard
                    }
                    .padding(16)
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $shareItem) { item in
                ShareSheet(fileURL: item.fileURL)
            }
            .sheet(isPresented: $showingCookieSettings) {
                CookieSettingsView(model: model)
            }
            .alert("下载失败", isPresented: Binding(
                get: { model.errorText != nil },
                set: { if !$0 { model.cancelMessage() } }
            )) {
                Button("知道了", role: .cancel) { model.cancelMessage() }
            } message: {
                Text(model.errorText ?? "未知错误")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.blue.gradient)
                    .frame(width: 50, height: 50)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("本地下载器")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                Text("手机直连 YouTube · 不经过你的服务器")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private var composer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                TextField("粘贴 YouTube 或 Shorts 链接", text: $model.urlText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(2...4)
                    .padding(14)
                    .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button("粘贴") {
                    model.urlText = UIPasteboard.general.string ?? ""
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }

            Picker("类型", selection: $model.kind) {
                ForEach(DownloadKind.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if model.kind == .video {
                HStack {
                    Label("最高画质", systemImage: "sparkles.tv")
                    Spacer()
                    Picker("画质", selection: $model.quality) {
                        ForEach(VideoQuality.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(14)
                .background(.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Button {
                showingCookieSettings = true
            } label: {
                HStack {
                    Label("YouTube Cookie", systemImage: "key.fill")
                    Spacer()
                    Text(model.hasCookie ? "已保存" : "未设置")
                        .foregroundStyle(model.hasCookie ? Color.green : Color.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(action: model.start) {
                HStack {
                    if model.isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.down.to.line.compact")
                    }
                    Text(model.isBusy ? "正在处理" : "开始下载")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 17))
            .disabled(model.isBusy || model.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .glassCard()
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("任务状态").font(.headline)
                Spacer()
                Text("\(Int(model.progress * 100))%")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.blue)
            }
            ProgressView(value: model.progress)
                .tint(.blue)
            Text(model.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let file = model.latestFile {
                Button {
                    shareItem = ShareItem(fileURL: file)
                } label: {
                    Label("保存到照片或文件", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .glassCard()
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本机文件").font(.headline)
                Spacer()
                Text("\(model.savedFiles.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.blue.opacity(0.12), in: Capsule())
            }

            if model.savedFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("暂无文件").font(.headline)
                    Text("完成的下载会出现在这里")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(model.savedFiles, id: \.self) { file in
                    HStack(spacing: 10) {
                        Image(systemName: file.pathExtension.lowercased() == "m4a" ? "waveform" : "film.fill")
                            .foregroundStyle(.blue)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.deletingPathExtension().lastPathComponent)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text(model.fileSizeText(file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { shareItem = ShareItem(fileURL: file) } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Button(role: .destructive) { model.delete(file) } label: {
                            Image(systemName: "trash")
                        }
                    }
                    .padding(.vertical, 7)
                    if file != model.savedFiles.last { Divider() }
                }
            }
        }
        .glassCard()
    }
}

private struct CookieSettingsView: View {
    @ObservedObject var model: DownloadViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingYouTubeBrowser = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingYouTubeBrowser = true
                    } label: {
                        Label("打开内置浏览器登录", systemImage: "safari")
                    }

                    SecureField("粘贴完整 Cookie 字符串", text: $model.cookieText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("从剪贴板粘贴") {
                        model.cookieText = UIPasteboard.general.string ?? ""
                    }

                    Button("保存到本机 Keychain") {
                        model.saveCookie()
                    }
                    .disabled(model.cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if model.hasCookie {
                        Button("清除 Cookie", role: .destructive) {
                            model.clearCookie()
                            WKWebsiteDataStore.default().removeData(
                                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                modifiedSince: .distantPast
                            ) { }
                        }
                    }
                } header: {
                    Text("YouTube Cookie")
                } footer: {
                    Text(model.cookieMessage)
                }

                Section {
                    Text("SAPISID")
                    Text("__Secure-1PAPISID")
                    Text("__Secure-1PSID")
                } header: {
                    Text("需要的字段")
                } footer: {
                    Text("只使用你自己的 YouTube Cookie。Cookie 相当于登录凭证，过期后需要重新粘贴。")
                }
            }
            .navigationTitle("Cookie 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .fullScreenCover(isPresented: $showingYouTubeBrowser) {
            YouTubeBrowserLoginView(model: model)
        }
    }
}

private struct YouTubeBrowserLoginView: View {
    @ObservedObject var model: DownloadViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var statusText = "请在页面中登录 YouTube，登录成功后会自动读取 Cookie。"

    var body: some View {
        NavigationStack {
            YouTubeLoginWebView(statusText: $statusText) { cookie in
                model.cookieText = cookie
                model.saveCookie()
                statusText = model.hasCookie
                    ? "登录 Cookie 已自动保存，可以关闭浏览器。"
                    : model.cookieMessage
            }
            .safeAreaInset(edge: .bottom) {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(model.hasCookie ? Color.green : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
            }
            .navigationTitle("登录 YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

private struct YouTubeLoginWebView: UIViewRepresentable {
    @Binding var statusText: String
    let onCookieFound: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView

        configuration.websiteDataStore.httpCookieStore.add(context.coordinator)

        if let url = URL(string: "https://www.youtube.com/") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        var parent: YouTubeLoginWebView
        weak var webView: WKWebView?
        private var lastCookie = ""

        init(parent: YouTubeLoginWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            inspectCookies()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: Error
        ) {
            parent.statusText = "页面加载失败：\(error.localizedDescription)"
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            parent.statusText = "无法打开登录页面：\(error.localizedDescription)"
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil,
               let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            inspectCookies()
        }

        private func inspectCookies() {
            guard let webView else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }

                let allowedNames: Set<String> = [
                    "SAPISID", "APISID", "SID", "HSID", "SSID",
                    "__Secure-1PAPISID", "__Secure-1PSID", "__Secure-1PSIDTS",
                    "__Secure-3PAPISID", "__Secure-3PSID", "__Secure-3PSIDTS",
                    "LOGIN_INFO", "VISITOR_INFO1_LIVE", "YSC", "PREF"
                ]

                let matching = cookies.filter { cookie in
                    let domain = cookie.domain.lowercased()
                    return allowedNames.contains(cookie.name) &&
                        (domain.contains("youtube.com") || domain.contains("google.com"))
                }

                var cookiesByName: [String: HTTPCookie] = [:]
                for cookie in matching {
                    let current = cookiesByName[cookie.name]
                    if current == nil || cookie.domain.lowercased().contains("youtube.com") {
                        cookiesByName[cookie.name] = cookie
                    }
                }

                let selectedCookies = Array(cookiesByName.values)
                let names = Set(selectedCookies.map(\.name))
                let hasSAPISID = names.contains("SAPISID")
                let hasPAPISID = names.contains("__Secure-1PAPISID") || names.contains("__Secure-3PAPISID")
                let hasPSID = names.contains("__Secure-1PSID") || names.contains("__Secure-3PSID")

                guard hasSAPISID, hasPAPISID, hasPSID else {
                    self.parent.statusText = "浏览器已打开；完成 Google 登录后会自动保存 Cookie。"
                    return
                }

                let cookieHeader = selectedCookies
                    .sorted { $0.name < $1.name }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")

                guard !cookieHeader.isEmpty, cookieHeader != self.lastCookie else { return }
                self.lastCookie = cookieHeader
                self.parent.onCookieFound(cookieHeader)
            }
        }
    }
}

private extension View {
    func glassCard() -> some View {
        self
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .stroke(.white.opacity(0.75), lineWidth: 1)
            }
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let fileURL: URL
}

#Preview {
    ContentView()
}
