import AVFoundation
import Foundation
import UIKit

enum BackgroundSessionEvents {
    private static var handlers: [String: () -> Void] = [:]
    private static let lock = NSLock()

    static func store(identifier: String, completion: @escaping () -> Void) {
        lock.lock()
        handlers[identifier] = completion
        lock.unlock()
    }

    static func finish(identifier: String) {
        lock.lock()
        let completion = handlers.removeValue(forKey: identifier)
        lock.unlock()
        DispatchQueue.main.async { completion?() }
    }
}

struct TransferProgress: Sendable {
    let fraction: Double
    let bytesWritten: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double
    let remainingSeconds: TimeInterval?
}

final class DownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (TransferProgress) -> Void)?
    private var fileExtension = "mp4"
    private var expectedLength: Int64 = 0
    private var lastSampleDate = Date()
    private var lastSampleBytes: Int64 = 0
    private var smoothedSpeed = 0.0
    private var session: URLSession?

    func download(
        source: MediaSource,
        allowsCellular: Bool,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> URL {
        DiagnosticLogger.shared.info("创建后台下载; host=\(source.url.host ?? "unknown"); expectedBytes=\(source.contentLength ?? 0); cellular=\(allowsCellular)")
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.progressHandler = progress
            self.fileExtension = source.width == nil ? "m4a" : "mp4"
            self.expectedLength = source.contentLength ?? 0
            self.lastSampleDate = Date()
            self.lastSampleBytes = 0
            self.smoothedSpeed = 0

            let identifier = "cn.local.YouTubeNativeDownloader.transfer.\(UUID().uuidString)"
            let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            configuration.isDiscretionary = false
            configuration.sessionSendsLaunchEvents = true
            configuration.allowsCellularAccess = allowsCellular
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 60 * 60 * 6
            configuration.waitsForConnectivity = true
            configuration.httpMaximumConnectionsPerHost = 4

            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session

            var request = URLRequest(url: source.url)
            request.timeoutInterval = 60
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
                forHTTPHeaderField: "User-Agent"
            )
            session.downloadTask(with: request).resume()
        }
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
            let current = Double(totalBytesWritten - lastSampleBytes) / elapsed
            smoothedSpeed = smoothedSpeed == 0 ? current : (smoothedSpeed * 0.72 + current * 0.28)
            lastSampleDate = now
            lastSampleBytes = totalBytesWritten
        }

        let fraction = total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : 0
        let remaining: TimeInterval?
        if total > totalBytesWritten, smoothedSpeed > 1 {
            remaining = Double(total - totalBytesWritten) / smoothedSpeed
        } else {
            remaining = nil
        }
        progressHandler?(TransferProgress(
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
            DiagnosticLogger.shared.warning("下载 HTTP 失败; host=\(response.url?.host ?? "unknown"); HTTP=\(response.statusCode)")
            finish(.failure(DownloaderError.badHTTPStatus(response.statusCode)))
            return
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            DiagnosticLogger.shared.info("后台下载完成; host=\(downloadTask.originalRequest?.url?.host ?? "unknown"); bytes=\(size)")
            finish(.success(destination))
        } catch {
            DiagnosticLogger.shared.error(error, stage: "移动后台下载临时文件")
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            DiagnosticLogger.shared.error(error, stage: "后台下载 URLSession")
            finish(.failure(error))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        BackgroundSessionEvents.finish(identifier: identifier)
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        self.progressHandler = nil
        session?.finishTasksAndInvalidate()
        session = nil
        continuation.resume(with: result)
    }
}

enum MediaFileBuilder {
    static func mergeToMOV(
        videoURL: URL,
        audioURL: URL,
        title: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        DiagnosticLogger.shared.info("准备 AVFoundation 合并; video=\(videoURL.lastPathComponent); audio=\(audioURL.lastPathComponent)")
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()

        guard let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let targetVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw DownloaderError.mergeFailed("读取不到视频轨道")
        }
        let videoDuration = try await videoAsset.load(.duration)
        try targetVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideoTrack,
            at: .zero
        )
        targetVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        guard let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let targetAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw DownloaderError.mergeFailed("读取不到音频轨道")
        }
        let audioDuration = try await audioAsset.load(.duration)
        try targetAudioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTimeMinimum(videoDuration, audioDuration)),
            of: sourceAudioTrack,
            at: .zero
        )

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw DownloaderError.mergeFailed("无法创建导出任务")
        }
        let output = uniqueDocumentURL(title: title, extension: "mov")
        exporter.outputURL = output
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = true
        try await export(exporter, progress: progress)
        DiagnosticLogger.shared.info("AVFoundation 导出完成; output=\(output.lastPathComponent)")
        return output
    }

    static func saveAudio(sourceURL: URL, title: String) throws -> URL {
        let output = uniqueDocumentURL(title: title, extension: "m4a")
        try FileManager.default.moveItem(at: sourceURL, to: output)
        return output
    }

    private static func export(
        _ exporter: AVAssetExportSession,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let progressTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            progressTimer.schedule(deadline: .now(), repeating: .milliseconds(250))
            progressTimer.setEventHandler {
                progress(min(0.99, max(0, Double(exporter.progress))))
            }
            progressTimer.resume()

            exporter.exportAsynchronously {
                progressTimer.cancel()
                switch exporter.status {
                case .completed:
                    progress(1)
                    continuation.resume()
                case .failed, .cancelled:
                    if let error = exporter.error {
                        DiagnosticLogger.shared.error(error, stage: "AVFoundation 导出")
                    }
                    continuation.resume(throwing: DownloaderError.mergeFailed(
                        exporter.error?.localizedDescription ?? "导出被取消"
                    ))
                default:
                    continuation.resume(throwing: DownloaderError.mergeFailed("导出状态异常"))
                }
            }
        }
    }

    private static func uniqueDocumentURL(title: String, extension fileExtension: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        let cleanTitle = title
            .components(separatedBy: invalid)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = String((cleanTitle.isEmpty ? "YouTube" : cleanTitle).prefix(120))
        var candidate = documents.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = documents.appendingPathComponent("\(base) \(counter)").appendingPathExtension(fileExtension)
            counter += 1
        }
        return candidate
    }
}
