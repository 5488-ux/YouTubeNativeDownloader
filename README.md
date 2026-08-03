# 本地下载器 iOS

原生 SwiftUI YouTube 下载器，支持 iOS 16.1 及以上版本（含 iOS 26）。YouTube 页面解析、媒体下载和音视频合并均由 iPhone 完成；4.3 的服务器只生成每视频 PO Token 并解开 `n` 播放器挑战，不中转媒体。

## 4.3 功能

- 支持普通 YouTube、`youtu.be`、Shorts、Embed 和 Live 链接。
- 支持最佳画质、1080P、720P、480P，优先选择 iPhone 兼容的 H.264 视频与 AAC 音频。
- 使用 iPhone 直接请求 YouTube Innertube，不连接旧的 `youtube.789113.cn/ios-api/resolve` 解析接口。
- 设置中可以粘贴 Cookie 请求头、Netscape `cookies.txt` 或常见 JSON Cookie 导出。
- Cookie 仅保存在 iOS 钥匙串，不写入诊断日志。
- Cookie 鉴权根据客户端能力分流，并支持三种 SAPISID 哈希及多账号/品牌频道会话头。
- 每个视频自动向轻量授权服务请求 PO Token 并处理 `n` 播放器挑战，解决 MWEB 媒体直链 HTTP 403；请求只包含视频 ID、播放器版本地址和挑战短串。
- Token 服务不接收 Cookie、不返回媒体文件，也不承担视频中转流量。
- 如果 YouTube 返回可用 HLS，仍可由 iPhone 本机封装为 MP4。
- iPhone 直接从 YouTube/Google 媒体地址下载，不再使用服务器中转。
- 视频和 AAC 分别下载，完成后使用标准 WASI FFmpeg 5.1.7 在手机上无损合并为 MP4。
- MP4 自动保存到照片，同时在 App 文件中保留副本；音频保存为 M4A。
- 显示本机解析、视频下载、音频下载和 FFmpeg 合并的分阶段进度。
- 显示下载速度、传输大小、剩余时间、后台任务、灵动岛和锁屏 Live Activity。
- 下载完成或失败通知、详细诊断日志、本机文件查看、分享和删除。
- 明亮高对比度界面、版本折叠更新日志、每个新版本首次启动更新弹窗。

## Cookie

当 YouTube 提示需要登录或确认不是机器人时：

1. 在自己的浏览器登录 YouTube。
2. 使用 Cookie 导出工具复制 `youtube.com` Cookie。
3. 打开 App 的“设置 → YouTube Cookie”。
4. 粘贴并保存，然后重新下载。

Cookie 等同账号登录凭证，不要发送给任何人。Cookie 失效后需要重新导出。

## 本机解析限制

页面解析仍在本机完成，但 YouTube 当前要求媒体直链携带每视频 PO Token，因此 4.3 会连接 `youtube.789113.cn/ios-api/pot` 获取几百字节 Token。YouTube 会继续修改 Innertube、签名和验证规则；无法直连 `youtube.com` 或 `googlevideo.com` 的网络环境仍无法下载，因为媒体中转已删除。

## FFmpeg WASI 组件

首次启动可选择下载约 17.1 MB 的完整组件。组件现在作为本 GitHub 仓库的静态文件提供，不再从自建服务器下载。App 会校验：

- 大小：`17147310` 字节
- SHA-256：`350bc217d25ab9226b5a064eaabd82354496e3a409f8be77a61e12271179f308`

组件只负责 iPhone 本机音视频合并，不执行服务器转码。

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
