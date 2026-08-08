@preconcurrency import AVFoundation
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

enum TransferSessionMode: String, Sendable {
    case background = "后台"
    case foreground = "前台兜底"
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
    private var didAttemptResume = false

    func download(
        source: MediaSource,
        allowsCellular: Bool,
        mode: TransferSessionMode = .background,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> URL {
        DiagnosticLogger.shared.info(
            "创建\(mode.rawValue)下载; host=\(source.url.host ?? "unknown"); " +
            "expectedBytes=\(source.contentLength ?? 0); cellular=\(allowsCellular)"
        )
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.progressHandler = progress
            self.fileExtension = source.width == nil ? "m4a" : "mp4"
            self.expectedLength = source.contentLength ?? 0
            self.lastSampleDate = Date()
            self.lastSampleBytes = 0
            self.smoothedSpeed = 0
            self.didAttemptResume = false

            let configuration: URLSessionConfiguration
            if mode == .background {
                let identifier = "cn.local.YouTubeNativeDownloader.transfer.\(UUID().uuidString)"
                configuration = URLSessionConfiguration.background(withIdentifier: identifier)
                configuration.sessionSendsLaunchEvents = true
            } else {
                configuration = URLSessionConfiguration.default
            }
            configuration.isDiscretionary = false
            configuration.allowsCellularAccess = allowsCellular
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 60 * 60 * 6
            configuration.waitsForConnectivity = true
            configuration.httpMaximumConnectionsPerHost = 4

            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session

            var request = URLRequest(url: source.url)
            request.timeoutInterval = 60
            for (name, value) in source.httpHeaders {
                request.setValue(value, forHTTPHeaderField: name)
            }
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue(
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
                    forHTTPHeaderField: "User-Agent"
                )
            }
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
            let responseLength = downloadTask.response?.expectedContentLength ?? NSURLSessionTransferSizeUnknown
            if responseLength > 0, Int64(size) < responseLength * 99 / 100 {
                try? FileManager.default.removeItem(at: destination)
                DiagnosticLogger.shared.warning("下载文件不完整; actual=\(size); expected=\(responseLength)")
                finish(.failure(DownloaderError.downloadFailed))
                return
            }
            DiagnosticLogger.shared.info("后台下载完成; host=\(downloadTask.originalRequest?.url?.host ?? "unknown"); bytes=\(size)")
            finish(.success(destination))
        } catch {
            DiagnosticLogger.shared.error(error, stage: "移动后台下载临时文件")
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, continuation != nil {
            let nsError = error as NSError
            if !didAttemptResume,
               let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               !resumeData.isEmpty {
                didAttemptResume = true
                DiagnosticLogger.shared.warning(
                    "后台下载中断，使用系统断点数据自动续传; bytes=\(resumeData.count)"
                )
                session.downloadTask(withResumeData: resumeData).resume()
                return
            }
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
    static func exportHLSVideo(
        source: MediaSource,
        title: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        DiagnosticLogger.shared.info(
            "准备 AVFoundation HLS 导出; host=\(source.url.host ?? "unknown"); " +
            "resolution=\(source.width ?? 0)x\(source.height ?? 0)"
        )
        let options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            "AVURLAssetHTTPHeaderFieldsKey": source.httpHeaders
        ]
        let asset = AVURLAsset(url: source.url, options: options)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard playable, duration.isNumeric, !videoTracks.isEmpty, !audioTracks.isEmpty else {
            throw DownloaderError.mergeFailed("HLS 清单缺少可导出的视频轨或音频轨")
        }

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw DownloaderError.mergeFailed("无法创建 HLS 导出任务")
        }
        let output = uniqueDocumentURL(title: title, extension: "mp4")
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        try await export(exporter, progress: progress)
        try await validateOutput(output, expectedDuration: duration)
        DiagnosticLogger.shared.info(
            "HLS 本机导出完成; output=\(output.lastPathComponent); bytes=\((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)"
        )
        return output
    }

    static func mergeToMOV(
        videoURL: URL,
        audioURL: URL,
        title: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        DiagnosticLogger.shared.info("准备 AVFoundation 合并; video=\(videoURL.lastPathComponent); audio=\(audioURL.lastPathComponent)")
        let preciseTiming = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        let videoAsset = AVURLAsset(url: videoURL, options: preciseTiming)
        let audioAsset = AVURLAsset(url: audioURL, options: preciseTiming)
        let composition = AVMutableComposition()

        guard let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let targetVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw DownloaderError.mergeFailed("读取不到视频轨道")
        }
        let videoTimeRange = try await sourceVideoTrack.load(.timeRange)
        guard Self.isUsable(videoTimeRange) else {
            throw DownloaderError.mergeFailed("视频轨道时间范围无效")
        }

        guard let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let targetAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw DownloaderError.mergeFailed("读取不到音频轨道")
        }
        let audioTimeRange = try await sourceAudioTrack.load(.timeRange)
        guard Self.isUsable(audioTimeRange) else {
            throw DownloaderError.mergeFailed("音频轨道时间范围无效")
        }

        let commonDuration = CMTimeMinimum(videoTimeRange.duration, audioTimeRange.duration)
        guard commonDuration.isNumeric, CMTimeCompare(commonDuration, .zero) > 0 else {
            throw DownloaderError.mergeFailed("音视频共同时间范围无效")
        }
        let normalizedRange = CMTimeRange(start: .zero, duration: commonDuration)
        DiagnosticLogger.shared.info(
            "轨道时间轴; videoStart=\(CMTimeGetSeconds(videoTimeRange.start)); " +
            "videoDuration=\(CMTimeGetSeconds(videoTimeRange.duration)); " +
            "audioStart=\(CMTimeGetSeconds(audioTimeRange.start)); " +
            "audioDuration=\(CMTimeGetSeconds(audioTimeRange.duration)); " +
            "outputDuration=\(CMTimeGetSeconds(commonDuration))"
        )

        try targetVideoTrack.insertTimeRange(
            CMTimeRange(start: videoTimeRange.start, duration: commonDuration),
            of: sourceVideoTrack,
            at: .zero
        )
        targetVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        try targetAudioTrack.insertTimeRange(
            CMTimeRange(start: audioTimeRange.start, duration: commonDuration),
            of: sourceAudioTrack,
            at: .zero
        )

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw DownloaderError.mergeFailed("无法创建导出任务")
        }
        let output = uniqueDocumentURL(title: title, extension: "mov")
        exporter.outputURL = output
        exporter.outputFileType = .mov
        exporter.timeRange = normalizedRange
        exporter.shouldOptimizeForNetworkUse = true
        try await export(exporter, progress: progress)
        try await validateOutput(output, expectedDuration: commonDuration)
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

    private static func validateOutput(_ output: URL, expectedDuration: CMTime) async throws {
        let asset = AVURLAsset(
            url: output,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let actualSeconds = CMTimeGetSeconds(duration)
        let expectedSeconds = CMTimeGetSeconds(expectedDuration)
        guard playable,
              !videoTracks.isEmpty,
              !audioTracks.isEmpty,
              actualSeconds.isFinite,
              abs(actualSeconds - expectedSeconds) <= 0.75 else {
            try? FileManager.default.removeItem(at: output)
            throw DownloaderError.mergeFailed(
                "成品时间轴校验失败（输出 \(actualSeconds) 秒，预期 \(expectedSeconds) 秒）"
            )
        }
        DiagnosticLogger.shared.info("MOV 校验通过; duration=\(actualSeconds); videoTracks=\(videoTracks.count); audioTracks=\(audioTracks.count)")
    }

    private static func isUsable(_ range: CMTimeRange) -> Bool {
        range.isValid &&
        range.start.isNumeric &&
        range.duration.isNumeric &&
        CMTimeCompare(range.duration, .zero) > 0
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
