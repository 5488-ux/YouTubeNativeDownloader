import CryptoKit
import Combine
import Foundation

enum FFmpegComponentState: Equatable {
    case notInstalled
    case downloading
    case verifying
    case installed
    case failed(String)
}

struct ComponentTransferProgress: Sendable {
    let fraction: Double
    let bytesWritten: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double
    let remainingSeconds: TimeInterval?
}

final class ComponentDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (ComponentTransferProgress) -> Void)?
    private var session: URLSession?
    private var expectedLength: Int64 = 0
    private var lastSampleDate = Date()
    private var lastSampleBytes: Int64 = 0
    private var smoothedSpeed = 0.0

    func download(
        from url: URL,
        expectedLength: Int64,
        allowsCellular: Bool,
        progress: @escaping @Sendable (ComponentTransferProgress) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.progressHandler = progress
            self.expectedLength = expectedLength
            self.lastSampleDate = Date()
            self.lastSampleBytes = 0
            self.smoothedSpeed = 0

            let configuration = URLSessionConfiguration.default
            configuration.allowsCellularAccess = allowsCellular
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60 * 60
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session

            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("YouTubeNativeDownloader/5.0", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    func cancel() {
        session?.invalidateAndCancel()
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedLength
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleDate)
        if elapsed >= 0.35 {
            let currentSpeed = Double(totalBytesWritten - lastSampleBytes) / elapsed
            smoothedSpeed = smoothedSpeed == 0 ? currentSpeed : smoothedSpeed * 0.72 + currentSpeed * 0.28
            lastSampleDate = now
            lastSampleBytes = totalBytesWritten
        }

        let fraction = total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : 0
        let remaining = total > totalBytesWritten && smoothedSpeed > 1
            ? Double(total - totalBytesWritten) / smoothedSpeed
            : nil
        progressHandler?(ComponentTransferProgress(
            fraction: fraction,
            bytesWritten: totalBytesWritten,
            totalBytes: total,
            bytesPerSecond: smoothedSpeed,
            remainingSeconds: remaining
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            finish(.failure(DownloaderError.badHTTPStatus(response.statusCode)))
            return
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffmpeg-\(UUID().uuidString)")
            .appendingPathExtension("wasm")
        do {
            try FileManager.default.moveItem(at: location, to: temporaryURL)
            finish(.success(temporaryURL))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        progressHandler = nil
        session?.finishTasksAndInvalidate()
        session = nil
        continuation.resume(with: result)
    }
}

@MainActor
final class FFmpegComponentManager: ObservableObject {
    static let shared = FFmpegComponentManager()

    static let componentVersion = "ffmpeg-wasi-5.1.7-r1"
    static let expectedBytes: Int64 = 17_147_310
    static let expectedSHA256 = "350bc217d25ab9226b5a064eaabd82354496e3a409f8be77a61e12271179f308"
    static let downloadURL = URL(
        string: "https://raw.githubusercontent.com/5488-ux/YouTubeNativeDownloader/main/components/ffmpeg-wasi-5.1.7-r1.wasm"
    )!

    @Published private(set) var state: FFmpegComponentState
    @Published private(set) var progress = 0.0
    @Published private(set) var speedText = "--"
    @Published private(set) var etaText = "--"
    @Published private(set) var transferredText = "--"

    private var activeTransfer: ComponentDownloadTransfer?

    private init() {
        state = Self.componentLooksInstalled ? .installed : .notInstalled
    }

    var isInstalled: Bool {
        if case .installed = state { return true }
        return false
    }

    var componentURL: URL? {
        isInstalled ? Self.installedURL : nil
    }

    var installedSizeText: String {
        guard let size = try? Self.installedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return "未安装"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    func install(allowsCellular: Bool) {
        guard state != .downloading && state != .verifying else { return }
        state = .downloading
        progress = 0
        speedText = "测速中"
        etaText = "计算中"
        transferredText = "0 MB / \(Self.sizeText(Self.expectedBytes))"
        DiagnosticLogger.shared.info("开始下载完整 FFmpeg WASM 组件; version=\(Self.componentVersion); bytes=\(Self.expectedBytes)")

        Task {
            do {
                var downloadedURL: URL?
                for attempt in 1...3 {
                    let transfer = ComponentDownloadTransfer()
                    activeTransfer = transfer
                    do {
                        downloadedURL = try await transfer.download(
                            from: Self.downloadURL,
                            expectedLength: Self.expectedBytes,
                            allowsCellular: allowsCellular
                        ) { [weak self] value in
                            Task { @MainActor in self?.apply(value) }
                        }
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard attempt < 3 else { throw error }
                        DiagnosticLogger.shared.warning(
                            "FFmpeg WASI 组件下载中断，自动重试 \(attempt)/2；\(error.localizedDescription)"
                        )
                        speedText = "正在重连"
                        etaText = "第 \(attempt) 次重试"
                        try await Task.sleep(for: .seconds(1))
                    }
                }

                guard let temporaryURL = downloadedURL else {
                    throw DownloaderError.componentInvalid("组件下载没有生成临时文件")
                }
                activeTransfer = nil
                state = .verifying
                speedText = "校验中"
                etaText = "即将完成"
                try await Self.verifyAndInstall(temporaryURL)
                progress = 1
                speedText = "已安装"
                etaText = "0 秒"
                transferredText = Self.sizeText(Self.expectedBytes)
                state = .installed
                DiagnosticLogger.shared.info("FFmpeg WASM 组件安装完成; sha256=\(Self.expectedSHA256)")
            } catch is CancellationError {
                activeTransfer = nil
                state = .notInstalled
                speedText = "--"
                etaText = "--"
                DiagnosticLogger.shared.warning("FFmpeg WASM 组件下载已取消")
            } catch {
                activeTransfer = nil
                state = .failed(error.localizedDescription)
                speedText = "--"
                etaText = "--"
                DiagnosticLogger.shared.error(error, stage: "安装 FFmpeg WASM 组件")
            }
        }
    }

    func cancelInstall() {
        activeTransfer?.cancel()
        activeTransfer = nil
    }

    func remove() {
        guard state != .downloading && state != .verifying else { return }
        try? FileManager.default.removeItem(at: Self.installedURL)
        UserDefaults.standard.removeObject(forKey: Keys.installedVersion)
        progress = 0
        speedText = "--"
        etaText = "--"
        transferredText = "--"
        state = .notInstalled
        DiagnosticLogger.shared.info("已删除 FFmpeg WASM 组件")
    }

    func recheck() {
        state = Self.componentLooksInstalled ? .installed : .notInstalled
    }

    private func apply(_ value: ComponentTransferProgress) {
        progress = value.fraction
        speedText = value.bytesPerSecond > 1
            ? Self.sizeText(Int64(value.bytesPerSecond)) + "/s"
            : "测速中"
        etaText = value.remainingSeconds.map(Self.durationText) ?? "计算中"
        transferredText = "\(Self.sizeText(value.bytesWritten)) / \(Self.sizeText(value.totalBytes))"
    }

    nonisolated private static func verifyAndInstall(_ temporaryURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
            guard Int64(values.fileSize ?? 0) == expectedBytes else {
                throw DownloaderError.componentInvalid("文件大小不正确")
            }
            let digest = try sha256(of: temporaryURL)
            guard digest == expectedSHA256 else {
                throw DownloaderError.componentInvalid("SHA-256 校验失败")
            }

            let directory = installedURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stagedURL = directory.appendingPathComponent("ffmpeg.installing.wasm")
            try? FileManager.default.removeItem(at: stagedURL)
            try FileManager.default.copyItem(at: temporaryURL, to: stagedURL)
            try? FileManager.default.removeItem(at: installedURL)
            try FileManager.default.moveItem(at: stagedURL, to: installedURL)
            UserDefaults.standard.set(componentVersion, forKey: Keys.installedVersion)
        }.value
    }

    nonisolated private static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static var componentLooksInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path) &&
        UserDefaults.standard.string(forKey: Keys.installedVersion) == componentVersion
    }

    nonisolated static var installedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FFmpeg", isDirectory: true)
            .appendingPathComponent("ffmpeg.wasm")
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        return value < 60 ? "剩余 \(value) 秒" : "剩余 \(value / 60) 分 \(value % 60) 秒"
    }

    private enum Keys {
        static let installedVersion = "ffmpeg.component.version"
    }
}
