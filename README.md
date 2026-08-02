# 本地下载器 iOS

原生 SwiftUI YouTube 下载器，支持 iOS 16.1–26。解析由服务器上的 `yt-dlp` 完成，下载、进度展示和音视频合并由 iPhone 处理。

## 3.0 功能

- 标准 YouTube、`youtu.be`、Shorts、Embed 和 Live 链接。
- H.264 视频 + AAC 音频，避免白屏只有声音。
- 最佳画质、1080P、720P、480P；视频下载后由 iPhone 使用 FFmpeg 无损合并为 MP4，音频保存为 M4A。
- 首次启动由用户选择是否下载完整 FFmpeg WASM 组件（约 19.7 MB），IPA 本身不携带 FFmpeg。
- 组件支持下载进度、速度、剩余时间、SHA-256 校验、重装和删除。
- 服务器解析、视频、AAC 和 FFmpeg 合并按当前阶段只显示当前进度条。
- 明亮液态玻璃界面，重做下载入口、任务状态和本机文件卡片。
- MP4 合并完成后自动写入 iPhone 照片，无需再打开系统分享弹窗手动保存。
- 设置中提供持久化详细错误日志，支持刷新、复制和清空。
- 设置中提供按类别整理的完整功能介绍。
- 视频与 AAC 均完整下载后再执行 FFmpeg `-c copy` 合并，并校验 MP4 成品音视频轨。
- 系统后台 `URLSession`，切到后台或锁屏后继续传输。
- 实时下载速度、已下载大小和预计剩余时间。
- Live Activity：锁屏进度和支持机型的灵动岛进度。
- 锁屏实时活动使用高对比度深色文字，避免白底字体过淡。
- 下载成功/失败本地通知。
- 设置页、更新日志和 GitHub 跳转。
- 不再内置浏览器，不在 App 内保存 YouTube Cookie。

## 解析接口

默认接口：`https://youtube.789113.cn/ios-api/resolve`

服务端源码在 `server/`：

- `ios-resolver.mjs`：调用 yt-dlp 解析格式、直链、请求头和文件大小；直链受出口 IP 限制时提供临时流式中转。
- `youtube-ios-resolver.service`：systemd 服务。
- `youtube-ios-resolver.nginx.conf`：Nginx 路由。

App 设置中可以修改解析接口地址。iPhone 优先直连媒体；服务器不运行 FFmpeg、不生成或永久保存视频，仅在直链受限时流式中转。

## Codemagic 无 Xcode 打包

仓库根目录已有 `codemagic.yaml`。推送 `main` 后运行 `iOS Unsigned IPA` workflow，产物为：

`build/ios/ipa/YouTubeNativeDownloader-unsigned.ipa`

这是未签名 IPA，需要使用你自己的证书或签名工具签名。IPA 内包含 Live Activity 扩展，签名时主 App 和 `.appex` 必须同时签名。

可以使用全能签签名
