import Foundation

enum DownloaderError: LocalizedError {
    case invalidURL
    case noCompatibleVideo
    case noCompatibleAudio
    case badHTTPStatus(Int)
    case downloadFailed
    case mergeFailed(String)
    case extractionFailed(String)
    case resolverUnavailable(String)
    case componentMissing
    case componentInvalid(String)
    case photoPermissionDenied
    case photoSaveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "链接无效，请粘贴 YouTube 视频或 Shorts 链接。"
        case .noCompatibleVideo:
            return "本机解析没有找到 iPhone 可播放的 H.264 视频。"
        case .noCompatibleAudio:
            return "本机解析没有找到 AAC 音频。"
        case .badHTTPStatus(let code):
            return "下载返回 HTTP \(code)，临时链接可能已过期，请重新开始。"
        case .downloadFailed:
            return "下载失败，请检查网络后重试。"
        case .mergeFailed(let message):
            return "音视频合并失败：\(message)"
        case .extractionFailed(let message):
            return "YouTube 解析失败：\(message)"
        case .resolverUnavailable(let message):
            return message
        case .componentMissing:
            return "尚未安装完整 FFmpeg 合并组件，请先到设置中下载。"
        case .componentInvalid(let message):
            return "FFmpeg 组件无效：\(message)"
        case .photoPermissionDenied:
            return "MP4 已下载完成，但没有照片写入权限。请到 iPhone 设置中允许本 App 添加照片。"
        case .photoSaveFailed(let message):
            return "MP4 已下载完成，但自动保存到照片失败：\(message)"
        }
    }
}
