@preconcurrency import AVFoundation
import Foundation
import WasmKit
import WasmKitWASI

enum FFmpegWasmRunner {
    static func mergeToMP4(
        videoURL: URL,
        audioURL: URL,
        title: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let componentURL = await FFmpegComponentManager.shared.componentURL else {
            throw DownloaderError.componentMissing
        }

        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        guard videoURL.standardizedFileURL.path.hasPrefix(temporaryRoot.path),
              audioURL.standardizedFileURL.path.hasPrefix(temporaryRoot.path) else {
            throw DownloaderError.mergeFailed("输入文件不在允许的本机临时目录")
        }

        let workDirectory = temporaryRoot
            .appendingPathComponent("ffmpeg-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let wasmOutput = workDirectory.appendingPathComponent("merged.mp4")
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let videoGuestPath = "/tmp/\(videoURL.lastPathComponent)"
        let audioGuestPath = "/tmp/\(audioURL.lastPathComponent)"
        let outputGuestPath = "/tmp/\(workDirectory.lastPathComponent)/merged.mp4"
        let inputBytes = max(1, fileBytes(videoURL) + fileBytes(audioURL))

        DiagnosticLogger.shared.info(
            "准备 FFmpeg WASM 合并; component=\(componentURL.lastPathComponent); " +
            "video=\(videoURL.lastPathComponent); audio=\(audioURL.lastPathComponent); inputBytes=\(inputBytes)"
        )
        progress(0.01)

        try await Task.detached(priority: .userInitiated) {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler {
                let currentBytes = fileBytes(wasmOutput)
                let fraction = min(0.97, max(0.02, Double(currentBytes) / Double(inputBytes)))
                progress(fraction)
            }
            timer.resume()
            defer { timer.cancel() }

            let wasmData = try Data(contentsOf: componentURL, options: [.mappedIfSafe])
            let module = try parseWasm(bytes: Array(wasmData))
            let arguments = [
                "ffmpeg",
                "-hide_banner",
                "-loglevel", "warning",
                "-y",
                "-fflags", "+genpts",
                "-i", videoGuestPath,
                "-i", audioGuestPath,
                "-map", "0:v:0",
                "-map", "1:a:0",
                "-c", "copy",
                "-avoid_negative_ts", "make_zero",
                "-movflags", "+faststart",
                outputGuestPath
            ]
            let wasi = try WASIBridgeToHost(
                args: arguments,
                environment: ["HOME": "/tmp"],
                preopens: ["/tmp": temporaryRoot.path]
            )
            let engine = Engine()
            let store = Store(engine: engine)
            var imports = Imports()
            wasi.link(to: &imports, store: store)
            let instance = try module.instantiate(store: store, imports: imports)
            let exitCode = try wasi.start(instance)
            guard exitCode == 0 else {
                throw DownloaderError.mergeFailed("FFmpeg 返回状态码 \(exitCode)")
            }
        }.value

        guard FileManager.default.fileExists(atPath: wasmOutput.path), fileBytes(wasmOutput) > 0 else {
            throw DownloaderError.mergeFailed("FFmpeg 没有生成成品文件")
        }
        progress(0.98)
        try await validateOutput(wasmOutput)

        let output = uniqueDocumentURL(title: title, extension: "mp4")
        try FileManager.default.moveItem(at: wasmOutput, to: output)
        progress(1)
        DiagnosticLogger.shared.info("FFmpeg WASM 合并完成; output=\(output.lastPathComponent); bytes=\(fileBytes(output))")
        return output
    }

    private static func validateOutput(_ output: URL) async throws {
        let asset = AVURLAsset(
            url: output,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let seconds = CMTimeGetSeconds(duration)
        guard playable,
              !videoTracks.isEmpty,
              !audioTracks.isEmpty,
              seconds.isFinite,
              seconds > 0 else {
            throw DownloaderError.mergeFailed("FFmpeg 成品校验失败，缺少有效音轨或视频轨")
        }
        DiagnosticLogger.shared.info(
            "FFmpeg MP4 校验通过; duration=\(seconds); videoTracks=\(videoTracks.count); audioTracks=\(audioTracks.count)"
        )
    }

    private static func fileBytes(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
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
