import Foundation

enum DownloaderError: LocalizedError {
    case invalidURL
    case noCompatibleVideo
    case noCompatibleAudio
    case badHTTPStatus(Int)
    case downloadFailed
    case mergeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "链接无效，请粘贴 YouTube 视频或 Shorts 链接。"
        case .noCompatibleVideo:
            return "没有找到 iPhone 可播放的 H.264 视频格式。"
        case .noCompatibleAudio:
            return "没有找到可下载的 AAC 音频格式。"
        case .badHTTPStatus(let code):
            return "下载服务器返回 HTTP \(code)。链接可能已经过期，请重试。"
        case .downloadFailed:
            return "下载失败，请检查网络后重试。"
        case .mergeFailed(let message):
            return "音视频合并失败：\(message)"
        }
    }
}
