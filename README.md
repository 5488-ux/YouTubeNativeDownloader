# 本地下载器 iOS

原生 SwiftUI YouTube 下载器，支持 iOS 16.1 及以上版本（含 iOS 26）。5.0 使用服务器 yt-dlp 解析，iPhone 只负责媒体下载、本机合并和保存。

## 5.0 功能

- 支持普通 YouTube、`youtu.be`、Shorts、Embed 和 Live 链接。
- 支持最佳画质、1080P、720P、480P，优先选择 iPhone 兼容的 H.264 视频与 AAC 音频。
- `youtube.789113.cn/ios-api/resolve` 只负责 yt-dlp 格式解析，返回标题、格式、临时媒体地址和必要请求头。
- 视频与 AAC 由 iPhone 直接从 YouTube/Google 媒体节点下载，媒体文件不经过解析服务器中转。
- 视频和音频独立下载，使用标准 WASI FFmpeg 5.1.7 在手机上无损合并为 MP4。
- MP4 自动保存到照片，同时在 App 文件中保留副本；音频保存为 M4A。
- 分阶段显示服务器解析、视频下载、音频下载和 FFmpeg 合并进度。
- 显示下载速度、传输大小、剩余时间、后台任务、灵动岛和锁屏 Live Activity。
- 支持完成/失败通知、详细诊断日志、本机文件查看、分享和删除。
- 解析连接中断、超时、限流或 Cloudflare 5xx 时自动重试三次。
- 设置中可修改解析接口，也可一键恢复默认地址。
- 明亮高对比度界面、折叠更新日志、每个新版本首次启动更新弹窗。

## 工作流程

1. iPhone 把 YouTube 链接、下载类型和画质提交给解析接口。
2. 服务器使用 yt-dlp 解析并返回视频、AAC 和必要请求头；服务器不下载成品。
3. iPhone 直连返回的媒体地址，分别下载视频和音频。
4. iPhone 使用用户安装的 FFmpeg WASI 组件合并 MP4，校验后自动保存到照片。

## 网络要求

手机需要能连接解析服务器和返回的 YouTube/Google 媒体节点。解析接口临时异常时 App 会自动重试；媒体临时地址过期时重新开始任务即可。

## FFmpeg WASI 组件

首次启动可选择下载约 17.1 MB 的完整组件。App 会校验：

- 大小：`17147310` 字节
- SHA-256：`350bc217d25ab9226b5a064eaabd82354496e3a409f8be77a61e12271179f308`

组件只在 iPhone 本机合并音视频，不执行服务器转码。

## Codemagic 打包

仓库根目录已经提供 `codemagic.yaml`，工作流名称：

```text
ios-unsigned-ipa
```

构建产物：

```text
build/ios/ipa/YouTubeNativeDownloader-unsigned.ipa
```

这是未签名 IPA，需要使用自己的证书、个人签名工具或对应侧载方式安装。无需本地 Xcode。
