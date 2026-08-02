# 本地下载器 iOS

原生 SwiftUI YouTube 下载器，支持 iOS 16.1–26。解析由服务器上的 `yt-dlp` 完成，下载、进度展示和音视频合并由 iPhone 处理。

## 2.8 功能

- 标准 YouTube、`youtu.be`、Shorts、Embed 和 Live 链接。
- H.264 视频 + AAC 音频，避免白屏只有声音。
- 最佳画质、1080P、720P、480P；视频下载后由 iPhone 合并转换为 MOV，音频保存为 M4A。
- 视频、AAC 音频和 MOV 本机转换使用互不挤占的独立进度条。
- 服务器解析、视频、AAC 和 MOV 转换按当前阶段只显示一条进度条。
- 明亮液态玻璃界面，重做下载入口、任务状态和本机文件卡片。
- MOV 转换完成后自动写入 iPhone 照片，无需再打开系统分享弹窗手动保存。
- 设置中提供持久化详细错误日志，支持刷新、复制和清空。
- 设置中提供按类别整理的完整功能介绍。
- 按音视频轨道真实时间范围归零合并，并校验下载完整性和 MOV 成品时间轴。
- 系统后台 `URLSession`，切到后台或锁屏后继续传输。
- 实时下载速度、已下载大小和预计剩余时间。
- Live Activity：锁屏进度和支持机型的灵动岛进度。
- 下载成功/失败本地通知。
- 设置页、更新日志和 GitHub 跳转。
- 不再内置浏览器，不在 App 内保存 YouTube Cookie。

## 解析接口

默认接口：`https://youtube.789113.cn/ios-api/resolve`

服务端源码在 `server/`：

- `ios-resolver.mjs`：yt-dlp 解析和带 Range 支持的媒体中转。
- `youtube-ios-resolver.service`：systemd 服务。
- `youtube-ios-resolver.nginx.conf`：Nginx 路由。

App 设置中可以修改解析接口地址。服务端下载令牌默认六小时失效，不永久保存视频。

## Codemagic 无 Xcode 打包

仓库根目录已有 `codemagic.yaml`。推送 `main` 后运行 `iOS Unsigned IPA` workflow，产物为：

`build/ios/ipa/YouTubeNativeDownloader-unsigned.ipa`

这是未签名 IPA，需要使用你自己的证书或签名工具签名。IPA 内包含 Live Activity 扩展，签名时主 App 和 `.appex` 必须同时签名。

可以使用全能签签名
