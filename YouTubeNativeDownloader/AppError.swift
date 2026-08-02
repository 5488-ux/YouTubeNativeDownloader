import Foundation

enum DownloaderError: LocalizedError {
    case invalidURL
    case invalidServerURL
    case noCompatibleVideo
    case noCompatibleAudio
    case badHTTPStatus(Int)
    case downloadFailed
    case mergeFailed(String)
    case extractionFailed(String)
    case resolverUnavailable(String)
    case photoPermissionDenied
    case photoSaveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "链接无效，请粘贴 YouTube 视频或 Shorts 链接。"
        case .invalidServerURL:
            return "解析服务器地址无效，请到设置里检查。"
        case .noCompatibleVideo:
            return "服务器没有找到 iPhone 可播放的 H.264 视频。"
        case .noCompatibleAudio:
            return "服务器没有找到 AAC 音频。"
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
        case .photoPermissionDenied:
            return "MOV 已下载完成，但没有照片写入权限。请到 iPhone 设置中允许本 App 添加照片。"
        case .photoSaveFailed(let message):
            return "MOV 已下载完成，但自动保存到照片失败：\(message)"
        }
    }
}
