# 本地下载器 iOS

这是一个纯原生 SwiftUI 工程，不打开 `youtube.789113.cn`，也不经过你的服务器传输视频。

解析由 iPhone 内的 [YouTubeKit](https://github.com/b5i/YouTubeKit) 完成；视频和音频由手机直接下载，再使用 AVFoundation 在本机无损封装成 MP4。

## 功能

- 支持标准 YouTube、`youtu.be`、Shorts、Embed 和 Live 链接。
- 视频固定选择 iPhone 兼容的 H.264，音频固定选择 AAC，避免 MP4 白屏只有声音。
- 支持最佳兼容、1080P、720P、480P。
- 支持视频 MP4 和音频 M4A。
- 下载完成后可保存到“照片”或“文件”。
- App 文稿目录可通过 iPhone“文件”App访问。

## 用 Xcode 打包

1. 在 Mac 安装 Xcode 16 或更新版本。
2. 解压工程，双击 `YouTubeNativeDownloader.xcodeproj`。
3. 等待 Xcode 自动拉取 YouTubeKit 依赖。
4. 选中项目里的 `YouTubeNativeDownloader` Target。
5. 打开 **Signing & Capabilities**：
   - Team 选择你自己的 Apple ID/开发者团队。
   - Bundle Identifier 改成你自己的唯一值，例如 `cn.example.localdownloader`。
6. 连接 iPhone，顶部设备选择你的 iPhone，按 `⌘R` 可直接安装测试。
7. 要导出 IPA：选择 **Product → Archive**，完成后在 Organizer 中选择 **Distribute App**。

免费 Apple ID 的签名通常只有 7 天有效期；正式开发者账号可使用更长期的开发或 Ad Hoc 签名。

## 重要限制

- 这是自签/侧载工程。包含 YouTube 下载功能的 App 很可能无法通过 App Store 审核。
- YouTube 会调整内部接口。工程跟踪 YouTubeKit 的 `main` 分支；解析失效时，在 Xcode 选择 **File → Packages → Update to Latest Package Versions**，然后重新打包。
- 部分登录、会员、年龄限制或地区限制视频仍可能需要账号 Cookie；当前版本不保存 Google 账号 Cookie。
- 请只保存你有权下载的内容。
