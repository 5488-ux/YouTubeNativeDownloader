# 本地下载器 iOS

原生 SwiftUI YouTube 下载器，支持 iOS 16.1 及以上版本（含 iOS 26）。4.6 已修复本机 WebKit 参数冲突，并加入由 iPhone 直连 YouTube 的 Cookie 登录状态测试。App 不调用自建解析、授权或媒体中转接口。

## 4.6 功能

- 支持普通 YouTube、`youtu.be`、Shorts、Embed 和 Live 链接。
- 支持最佳画质、1080P、720P、480P，优先选择 iPhone 兼容的 H.264 视频与 AAC 音频。
- iPhone 本机请求 YouTube 页面与 Innertube，提取视频信息和媒体格式。
- IPA 内置 BgUtils BotGuard，本机获取挑战并生成每视频 PO Token。
- Player Token 绑定视频 ID 并写入 Innertube 请求；GVS Token 独立绑定账号 Data Sync Session ID 或匿名 Visitor Data，不能混成同一枚。
- WEB/MWEB Player 通过隐藏 WebKit 网络栈请求，手动 Cookie、浏览器指纹、BotGuard 与 Token 保持在同一手机会话。
- IPA 内置 yt-dlp EJS，本机读取当前播放器脚本并解开 `n` 与 `signatureCipher` 播放器挑战。
- 不调用 `youtube.789113.cn/ios-api/resolve`、`/ios-api/media-access` 或 `/ios-api/pot`。
- 设置中可以粘贴 Cookie 请求头、Netscape `cookies.txt` 或常见 JSON Cookie 导出，并可点击“测试 Cookie”确认 YouTube 是否识别登录状态。
- Cookie 只保存在 iOS 钥匙串，不上传、不写入诊断日志。
- Cookie 鉴权根据客户端能力分流，并支持 SAPISID 哈希及多账号/品牌频道会话头。
- iPhone 直接从 YouTube/Google 媒体地址下载，不经过自建服务器。
- 视频和 AAC 独立下载，使用标准 WASI FFmpeg 5.1.7 在手机上无损合并为 MP4。
- MP4 自动保存到照片，同时在 App 文件中保留副本；音频保存为 M4A。
- 显示本机解析、视频下载、音频下载和 FFmpeg 合并的当前阶段进度。
- 显示下载速度、传输大小、剩余时间、后台任务、灵动岛和锁屏 Live Activity。
- 支持完成/失败通知、详细诊断日志、本机文件查看、分享和删除。
- 明亮高对比度界面、折叠更新日志、每个新版本首次启动更新弹窗。

## 完整本机流程

1. iPhone 获取 YouTube 页面、播放器地址、API Key、Visitor Data 和账号会话信息。
2. iPhone 请求 Innertube 并选择 H.264 视频与 AAC 音频。
3. 隐藏的系统 WebKit 运行 IPA 内置的 BgUtils，直接向 Google WAA 获取 BotGuard 挑战并生成 PO Token。
4. 同一运行环境下载当前 YouTube 播放器 JavaScript，交给 IPA 内置的 yt-dlp EJS 解开 `n` 与加密签名。
5. iPhone 修正媒体 URL，分别下载视频和音频。
6. iPhone 使用用户安装的 FFmpeg WASI 组件合并 MP4，校验轨道和时长后自动保存照片。

这里的 WebKit 只是本机 JavaScript 运行沙箱，没有可见浏览器、登录页或浏览记录界面。

## Cookie

当 YouTube 提示需要登录或确认不是机器人时：

1. 在自己的浏览器登录 YouTube。
2. 使用 Cookie 导出工具复制 `youtube.com` Cookie。
3. 打开 App 的“设置 → YouTube Cookie”。
4. 粘贴后点击“测试 Cookie”；确认登录状态有效后保存，再重新下载。

Cookie 等同账号登录凭证，不要发送给任何人。Cookie 失效后需要重新导出。

## 网络要求与限制

虽然不再依赖自建服务器，手机仍必须能直连 `youtube.com`、`googlevideo.com`、`googleapis.com` 和 Google WAA。YouTube 会持续修改 Innertube、播放器和 BotGuard；内置 EJS/BgUtils 以后仍可能需要随版本更新。

## FFmpeg WASI 组件

首次启动可选择下载约 17.1 MB 的完整组件。组件作为本 GitHub 仓库的静态文件提供，App 会校验：

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

## 内置第三方运行组件

- `yt-dlp/ejs`：播放器 JavaScript 提取与 `n`/签名挑战执行。
- `LuanRT/BgUtils`：BotGuard、WAA 与 Web PO Token 生成。
- EJS 包含 `meriyah` 与 `astring`；具体许可和可复现构建命令见 `RuntimeBuild/README.md`。
