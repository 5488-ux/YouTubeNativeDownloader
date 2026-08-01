import AVFoundation
import Foundation

final class DownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var fileExtension = "mp4"
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func download(source: MediaSource, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.progressHandler = progress
            self.fileExtension = source.width == nil ? "m4a" : "mp4"

            var request = URLRequest(url: source.url)
            request.timeoutInterval = 60
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            if let length = source.contentLength, length > 0 {
                request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
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
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
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

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        self.progressHandler = nil
        continuation.resume(with: result)
    }
}

enum MediaFileBuilder {
    static func merge(videoURL: URL, audioURL: URL, title: String) async throws -> URL {
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
        let finalDuration = CMTimeMinimum(videoDuration, audioDuration)
        try targetAudioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: finalDuration),
            of: sourceAudioTrack,
            at: .zero
        )

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw DownloaderError.mergeFailed("无法创建导出任务")
        }

        let output = uniqueDocumentURL(title: title, extension: "mp4")
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        try await export(exporter)
        return output
    }

    static func saveAudio(sourceURL: URL, title: String) throws -> URL {
        let output = uniqueDocumentURL(title: title, extension: "m4a")
        try FileManager.default.moveItem(at: sourceURL, to: output)
        return output
    }

    private static func export(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
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
            candidate = documents
                .appendingPathComponent("\(base) \(counter)")
                .appendingPathExtension(fileExtension)
            counter += 1
        }
        return candidate
    }
}
