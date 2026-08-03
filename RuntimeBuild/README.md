# IPA 本机 YouTube 运行组件

这两个 JavaScript 文件不是从服务器运行，而是作为 Xcode Resources 直接打进 IPA：

- `YouTubeNativeDownloader/RuntimeAssets/yt-ejs.bundle.js`
- `YouTubeNativeDownloader/RuntimeAssets/bgutils.bundle.js`

当前固定源码：

- yt-dlp/ejs commit `6f8587bb7009a1fc81038538071d2cb66b8b8ed0`
- LuanRT/BgUtils 4.0.2 commit `7256fadaa5c59eb77d6d051f570ce72fa16bf14e`

## 重新构建 yt-dlp EJS

```bash
git clone https://github.com/yt-dlp/ejs.git /tmp/yt-dlp-ejs
cd /tmp/yt-dlp-ejs
git checkout 6f8587bb7009a1fc81038538071d2cb66b8b8ed0
npm install
npx esbuild src/yt/solver/main.ts \
  --bundle \
  --platform=browser \
  --format=iife \
  --global-name=YTDLPEJS \
  --target=safari15 \
  --minify \
  --outfile=/path/to/YouTubeNativeDownloader/YouTubeNativeDownloader/RuntimeAssets/yt-ejs.bundle.js
```

## 重新构建 BgUtils

```bash
git clone https://github.com/LuanRT/BgUtils.git /tmp/bgutils
cd /tmp/bgutils
git checkout 7256fadaa5c59eb77d6d051f570ce72fa16bf14e
npm install
npm run build
cp /path/to/YouTubeNativeDownloader/RuntimeBuild/bgutils-entry.ts ./local-ios-entry.ts
npx esbuild ./local-ios-entry.ts \
  --bundle \
  --platform=browser \
  --format=iife \
  --target=safari15 \
  --minify \
  --outfile=/path/to/YouTubeNativeDownloader/YouTubeNativeDownloader/RuntimeAssets/bgutils.bundle.js
```

构建完成后执行：

```bash
node --check YouTubeNativeDownloader/RuntimeAssets/yt-ejs.bundle.js
node --check YouTubeNativeDownloader/RuntimeAssets/bgutils.bundle.js
```

不要把这两个资源改成构建时在线下载，否则 IPA 又会缺功能。

