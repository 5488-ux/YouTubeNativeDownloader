import Foundation
import UIKit

final class DiagnosticLogger {
    static let shared = DiagnosticLogger()

    private let queue = DispatchQueue(label: "cn.local.YouTubeNativeDownloader.diagnostic-log")
    private let maximumBytes = 512 * 1024
    private let logURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("downloader.log")
    }

    func beginSession(urlText: String, endpoint: URL, kind: DownloadKind, quality: VideoQuality) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        write("INFO", "========== 新任务 ==========")
        write("INFO", "App=\(version) (\(build)); iOS=\(UIDevice.current.systemVersion); device=\(UIDevice.current.model)")
        write("INFO", "type=\(kind.rawValue); quality=\(quality.rawValue); endpoint=\(Self.safeEndpoint(endpoint))")
        write("INFO", "input=\(Self.safeInput(urlText))")
    }

    private static func safeEndpoint(_ endpoint: URL) -> String {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint.host ?? "invalid"
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? (endpoint.host ?? "invalid")
    }

    func info(_ message: String) { write("INFO", message) }
    func warning(_ message: String) { write("WARN", message) }

    func error(_ error: Error, stage: String) {
        write("ERROR", "stage=\(stage); \(Self.describe(error))")
    }

    func text() -> String {
        queue.sync { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "暂无日志" }
    }

    func clear() {
        queue.sync { try? FileManager.default.removeItem(at: logURL) }
    }

    private func write(_ level: String, _ message: String) {
        queue.sync {
            rotateIfNeeded()
            let line = "[\(Self.timestamp.string(from: Date()))] [\(level)] \(message)\n"
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    private func rotateIfNeeded() {
        guard let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > maximumBytes else { return }
        let oldURL = logURL.deletingLastPathComponent().appendingPathComponent("downloader.previous.log")
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: logURL, to: oldURL)
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = [
            "description=\(error.localizedDescription)",
            "domain=\(nsError.domain)",
            "code=\(nsError.code)"
        ]
        let usefulInfo = nsError.userInfo
            .filter { entry in
                let name = String(describing: entry.key)
                return name != NSURLErrorFailingURLStringErrorKey && name != NSURLErrorFailingURLErrorKey
            }
            .map { "\($0.key)=\(String(describing: $0.value))" }
            .joined(separator: "; ")
        if !usefulInfo.isEmpty { parts.append("userInfo={\(usefulInfo)}") }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            let child = underlying as NSError
            parts.append("underlying={domain=\(child.domain); code=\(child.code); description=\(child.localizedDescription)}")
        }
        return parts.joined(separator: "; ")
    }

    private static func safeInput(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.queryItems = components.queryItems?.filter { $0.name == "v" }
        return components.string ?? trimmed
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
