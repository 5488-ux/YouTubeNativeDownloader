# AI 使用 Codemagic 制作 IPA 的通用指南

> 本文用于指导 AI 把任意可构建的 iOS 项目接入 GitHub 和 Codemagic，并产出真实可下载的 IPA。用户不需要 Mac，也不需要打开 Xcode。Codemagic 会在云端 macOS 构建机中调用 Xcode 工具链，这是苹果应用编译无法绕开的底层步骤。

## 一、AI 的任务目标

用户把一个项目交给 AI，并要求“制作 IPA”时，AI 应完成以下工作：

1. 检查项目是否真的包含 iOS 工程。
2. 判断项目类型。
3. 找到真实的工程、Workspace、Scheme、Target 和 Bundle Identifier。
4. 根据项目类型生成仓库根目录下的 `codemagic.yaml`。
5. 将配置和必要修复提交到 GitHub。
6. 指导用户在 Codemagic 添加 GitHub 仓库。
7. 使用 Codemagic 云端构建。
8. 根据真实构建日志修复问题并重新构建。
9. 验证 IPA 文件真实存在、结构正确，并明确它是否有签名。

AI 不得把以下情况冒充“IPA 已成功制作”：

- 只生成了源码压缩包。
- 只创建了 `codemagic.yaml`，但没有运行构建。
- Codemagic 显示构建成功，但 Artifacts 中没有 IPA。
- 只生成了 `.app`，没有打包为 IPA。
- 生成的是无签名 IPA，却告诉用户可以直接安装。
- Windows 本地语法检查通过，就声称 iOS 编译成功。

## 二、先确认用户需要哪种 IPA

### 1. 无签名 IPA

特点：

- 不需要 Apple Developer 证书。
- Codemagic 可以直接构建。
- 不能直接安装到普通 iPhone。
- 用户需要之后通过 AltStore、SideStore、企业签名、开发者证书或其他签名工具重新签名。

如果用户只说“帮我打一个 IPA”，又没有提供 Apple 开发者签名条件，AI 默认先制作无签名 IPA，并明确说明安装限制。

### 2. Development IPA

特点：

- 需要 Apple Development 证书。
- 需要 Development provisioning profile。
- 设备 UDID 必须包含在描述文件中。
- 适合开发测试。

### 3. Ad Hoc IPA

特点：

- 需要 Apple Distribution 证书。
- 需要 Ad Hoc provisioning profile。
- 只能安装到描述文件中登记的设备。

### 4. App Store IPA

特点：

- 需要 Apple Developer Program。
- 需要 App Store Connect API Key 或相应签名文件。
- 用于 TestFlight 或 App Store Connect。
- Bundle Identifier 必须与 App Store Connect 中的应用一致。

## 三、AI 必须先识别项目类型

AI 应在仓库中检查下列文件：

```bash
find . -maxdepth 4 \
  \( -name "*.xcodeproj" \
  -o -name "*.xcworkspace" \
  -o -name "pubspec.yaml" \
  -o -name "package.json" \
  -o -name "Podfile" \
  -o -name "capacitor.config.*" \
  -o -name "Package.swift" \)
```

判断规则：

| 特征 | 项目类型 | Codemagic 构建路线 |
| --- | --- | --- |
| `.xcodeproj` | 原生 iOS | `xcodebuild` 或 `xcode-project build-ipa` |
| `.xcworkspace` + `Podfile` | CocoaPods iOS | `pod install` 后构建 Workspace |
| `pubspec.yaml` + `ios/` | Flutter | `flutter build ios` 后打包或签名 |
| `package.json` + `ios/` | React Native | 安装 Node 依赖、Pods，再构建 Workspace |
| `capacitor.config.*` | Capacitor | Web Build、`cap sync ios`、Pods、构建 Workspace |
| 只有网页源码 | 不是 iOS 项目 | 必须先生成 Capacitor/原生壳，不能直接打 IPA |

如果项目根本没有 iOS 工程，AI 必须先说明缺少什么，再创建正确的 iOS 壳或请求必要信息。不能拿 HTML 压缩包硬说是 IPA。

## 四、AI 必须收集的真实构建信息

对原生 iOS、React Native 和 Capacitor 项目，AI 必须确定：

```text
XCODE_PROJECT      例如 MyApp.xcodeproj
XCODE_WORKSPACE    例如 MyApp.xcworkspace
XCODE_SCHEME       例如 MyApp
APP_NAME           例如 MyApp
BUNDLE_ID          例如 cn.example.myapp
DEPLOYMENT_TARGET  例如 16.0
```

不要用仓库名猜 Scheme。应在 Codemagic/macOS 环境中执行：

```bash
xcodebuild -list -json -project MyApp.xcodeproj
```

或者：

```bash
xcodebuild -list -json -workspace MyApp.xcworkspace
```

Scheme 必须为 Shared，并提交到 Git：

```text
MyApp.xcodeproj/xcshareddata/xcschemes/MyApp.xcscheme
```

不要依赖以下目录中的个人 Scheme：

```text
xcuserdata/
```

## 五、Codemagic 接入步骤

AI 完成 GitHub 仓库配置后，用户只需要：

1. 登录 Codemagic。
2. 点击 **Add application**。
3. 连接 GitHub。
4. 选择目标仓库。
5. 选择包含 `codemagic.yaml` 的分支。
6. 点击 **Check for configuration file**。
7. 选择正确的 Workflow。
8. 点击 **Start new build**。
9. 构建完成后，从 **Artifacts** 下载 IPA。

`codemagic.yaml` 必须：

- 位于仓库根目录。
- 文件名完全正确。
- 已经提交并推送到 Codemagic 扫描的分支。
- 使用空格缩进，不能混入 Tab。

## 六、通用原生 iOS 无签名 IPA 模板

AI 必须把模板中的项目名和 Scheme 改为真实值，不能原样复制占位符。

### 使用 `.xcodeproj`

```yaml
workflows:
  ios-unsigned-ipa:
    name: iOS Unsigned IPA
    max_build_duration: 60
    instance_type: mac_mini_m2

    environment:
      xcode: 26.4
      vars:
        XCODE_PROJECT: "MyApp.xcodeproj"
        XCODE_SCHEME: "MyApp"
        APP_NAME: "MyApp"

    scripts:
      - name: Show build environment
        script: |
          set -e
          xcodebuild -version
          sw_vers
          pwd

      - name: Verify project and scheme
        script: |
          set -e
          test -d "$CM_BUILD_DIR/$XCODE_PROJECT"
          xcodebuild -list \
            -project "$CM_BUILD_DIR/$XCODE_PROJECT"

      - name: Resolve Swift packages
        script: |
          set -e
          xcodebuild -resolvePackageDependencies \
            -project "$CM_BUILD_DIR/$XCODE_PROJECT" \
            -scheme "$XCODE_SCHEME"

      - name: Build unsigned iPhone app
        script: |
          set -e
          xcodebuild clean build \
            -project "$CM_BUILD_DIR/$XCODE_PROJECT" \
            -scheme "$XCODE_SCHEME" \
            -configuration Release \
            -sdk iphoneos \
            -destination "generic/platform=iOS" \
            -derivedDataPath "$CM_BUILD_DIR/build/DerivedData" \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO

      - name: Find and package app as IPA
        script: |
          set -e
          PRODUCTS_DIR="$CM_BUILD_DIR/build/DerivedData/Build/Products/Release-iphoneos"
          APP_PATH=$(find "$PRODUCTS_DIR" -maxdepth 1 -type d -name "*.app" | head -n 1)
          IPA_DIR="$CM_BUILD_DIR/build/ios/ipa"

          test -n "$APP_PATH"
          test -d "$APP_PATH"

          rm -rf "$IPA_DIR/Payload"
          mkdir -p "$IPA_DIR/Payload"
          cp -R "$APP_PATH" "$IPA_DIR/Payload/"

          cd "$IPA_DIR"
          /usr/bin/zip -qry "$APP_NAME-unsigned.ipa" Payload
          rm -rf Payload

          test -s "$IPA_DIR/$APP_NAME-unsigned.ipa"
          unzip -l "$IPA_DIR/$APP_NAME-unsigned.ipa" | head -50

    artifacts:
      - build/ios/ipa/*.ipa
      - build/DerivedData/Build/Products/Release-iphoneos/*.app
      - /tmp/xcodebuild_logs/*.log
```

## 七、CocoaPods / React Native / Capacitor 无签名模板

这类项目通常需要 `.xcworkspace`。AI 必须先安装依赖，再构建 Workspace。

```yaml
workflows:
  ios-workspace-unsigned-ipa:
    name: iOS Workspace Unsigned IPA
    max_build_duration: 90
    instance_type: mac_mini_m2

    environment:
      xcode: 26.4
      node: 22
      cocoapods: default
      vars:
        IOS_DIR: "ios"
        XCODE_WORKSPACE: "MyApp.xcworkspace"
        XCODE_SCHEME: "MyApp"
        APP_NAME: "MyApp"

    scripts:
      - name: Install JavaScript dependencies
        script: |
          set -e
          if [ -f package-lock.json ]; then
            npm ci
          elif [ -f yarn.lock ]; then
            corepack enable
            yarn install --frozen-lockfile
          else
            npm install
          fi

      - name: Build web assets when required
        script: |
          set -e
          if npm run | grep -q " build"; then
            npm run build
          fi

      - name: Sync Capacitor when present
        script: |
          set -e
          if [ -f capacitor.config.ts ] || [ -f capacitor.config.json ] || [ -f capacitor.config.js ]; then
            npx cap sync ios
          fi

      - name: Install CocoaPods
        script: |
          set -e
          cd "$CM_BUILD_DIR/$IOS_DIR"
          pod install --repo-update

      - name: Verify Workspace and Scheme
        script: |
          set -e
          test -d "$CM_BUILD_DIR/$IOS_DIR/$XCODE_WORKSPACE"
          xcodebuild -list \
            -workspace "$CM_BUILD_DIR/$IOS_DIR/$XCODE_WORKSPACE"

      - name: Build unsigned iPhone app
        script: |
          set -e
          xcodebuild clean build \
            -workspace "$CM_BUILD_DIR/$IOS_DIR/$XCODE_WORKSPACE" \
            -scheme "$XCODE_SCHEME" \
            -configuration Release \
            -sdk iphoneos \
            -destination "generic/platform=iOS" \
            -derivedDataPath "$CM_BUILD_DIR/build/DerivedData" \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO

      - name: Package unsigned IPA
        script: |
          set -e
          PRODUCTS_DIR="$CM_BUILD_DIR/build/DerivedData/Build/Products/Release-iphoneos"
          APP_PATH=$(find "$PRODUCTS_DIR" -maxdepth 1 -type d -name "*.app" | head -n 1)
          IPA_DIR="$CM_BUILD_DIR/build/ios/ipa"

          test -n "$APP_PATH"
          test -d "$APP_PATH"

          rm -rf "$IPA_DIR/Payload"
          mkdir -p "$IPA_DIR/Payload"
          cp -R "$APP_PATH" "$IPA_DIR/Payload/"

          cd "$IPA_DIR"
          /usr/bin/zip -qry "$APP_NAME-unsigned.ipa" Payload
          rm -rf Payload

          test -s "$IPA_DIR/$APP_NAME-unsigned.ipa"
          unzip -l "$IPA_DIR/$APP_NAME-unsigned.ipa" | head -50

    artifacts:
      - build/ios/ipa/*.ipa
      - /tmp/xcodebuild_logs/*.log
```

注意：不是所有 React Native 项目都有 `build` 脚本，AI 应阅读 `package.json` 后决定是否执行 `npm run build`，不要机械照抄。

## 八、Flutter 无签名 IPA 模板

```yaml
workflows:
  flutter-ios-unsigned-ipa:
    name: Flutter iOS Unsigned IPA
    max_build_duration: 60
    instance_type: mac_mini_m2

    environment:
      xcode: 26.4
      flutter: stable
      cocoapods: default
      vars:
        APP_NAME: "Runner"

    scripts:
      - name: Get Flutter packages
        script: |
          set -e
          flutter pub get

      - name: Build unsigned iOS app
        script: |
          set -e
          flutter build ios \
            --release \
            --no-codesign

      - name: Package unsigned IPA
        script: |
          set -e
          APP_PATH="$CM_BUILD_DIR/build/ios/iphoneos/Runner.app"
          IPA_DIR="$CM_BUILD_DIR/build/ios/ipa"

          test -d "$APP_PATH"
          rm -rf "$IPA_DIR/Payload"
          mkdir -p "$IPA_DIR/Payload"
          cp -R "$APP_PATH" "$IPA_DIR/Payload/"

          cd "$IPA_DIR"
          /usr/bin/zip -qry "$APP_NAME-unsigned.ipa" Payload
          rm -rf Payload

          test -s "$IPA_DIR/$APP_NAME-unsigned.ipa"
          unzip -l "$IPA_DIR/$APP_NAME-unsigned.ipa" | head -50

    artifacts:
      - build/ios/ipa/*.ipa
      - build/ios/iphoneos/*.app
```

## 九、Codemagic 签名 IPA 通用模板

只有用户已经配置 Apple Developer 签名条件时才使用。

用户需要在 Codemagic 中配置：

- App Store Connect API Key；或上传证书和描述文件。
- Apple Development / Apple Distribution 证书。
- 与 Bundle Identifier 匹配的 provisioning profile。
- 正确的分发类型。

任何私钥、证书密码和 Token 都不能写入 GitHub。

```yaml
workflows:
  ios-signed-ipa:
    name: iOS Signed IPA
    max_build_duration: 60
    instance_type: mac_mini_m2

    integrations:
      app_store_connect: codemagic

    environment:
      xcode: 26.4
      ios_signing:
        distribution_type: development
        bundle_identifier: cn.example.myapp
      vars:
        XCODE_PROJECT: "MyApp.xcodeproj"
        XCODE_SCHEME: "MyApp"

    scripts:
      - name: Resolve dependencies
        script: |
          set -e
          xcodebuild -resolvePackageDependencies \
            -project "$CM_BUILD_DIR/$XCODE_PROJECT" \
            -scheme "$XCODE_SCHEME"

      - name: Apply signing profiles
        script: xcode-project use-profiles

      - name: Build signed IPA
        script: |
          set -e
          xcode-project build-ipa \
            --project "$CM_BUILD_DIR/$XCODE_PROJECT" \
            --scheme "$XCODE_SCHEME"

    artifacts:
      - build/ios/ipa/*.ipa
      - /tmp/xcodebuild_logs/*.log
      - $HOME/Library/Developer/Xcode/DerivedData/**/Build/**/*.dSYM
```

分发类型：

```text
development  开发设备测试
ad_hoc       已登记设备分发
app_store    TestFlight / App Store
enterprise   企业内部分发
```

AI 不得自行猜测 Bundle Identifier、证书名称、团队或分发类型。

## 十、iOS 26 的处理方法

在 Codemagic 中选择支持 iOS 26 SDK 的 Xcode：

```yaml
environment:
  xcode: 26.4
```

需要分清两个概念：

```text
Xcode / SDK 版本：决定使用什么工具链编译。
Deployment Target：决定应用最低支持哪个 iOS 版本。
```

例如：

```text
Xcode：26.4
SDK：iOS 26
Deployment Target：iOS 16
结果：应用可运行在 iOS 16 及之后的系统，包括 iOS 26。
```

不要为了“适配 iOS 26”直接把最低系统改成 iOS 26。除非应用只能使用 iOS 26 专属 API，否则这是沙雕式砍兼容性。

## 十一、构建完成后必须验证 IPA

AI 必须在 Codemagic 脚本或日志中验证：

```bash
IPA_PATH=$(find "$CM_BUILD_DIR" -type f -name "*.ipa" | head -n 1)

test -n "$IPA_PATH"
test -s "$IPA_PATH"

echo "IPA: $IPA_PATH"
ls -lh "$IPA_PATH"
unzip -l "$IPA_PATH" | head -100
```

正确 IPA 至少包含：

```text
Payload/
Payload/应用名.app/
Payload/应用名.app/Info.plist
Payload/应用名.app/应用可执行文件
```

签名包还应检查：

```bash
rm -rf /tmp/ipa-check
mkdir -p /tmp/ipa-check
unzip -q "$IPA_PATH" -d /tmp/ipa-check
APP_PATH=$(find /tmp/ipa-check/Payload -maxdepth 1 -type d -name "*.app" | head -n 1)
codesign -dvvv "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
```

无签名 IPA 的 `codesign` 检查失败是正常的，但 AI 必须明确告诉用户它不能直接安装。

## 十二、常见问题

### 1. Codemagic 找不到 `codemagic.yaml`

检查：

- 文件是否位于仓库根目录。
- 文件名是否准确。
- 是否已提交并推送。
- Codemagic 是否扫描了正确分支。
- YAML 是否有缩进错误。

本地可检查：

```bash
npx --yes yaml-lint codemagic.yaml
```

### 2. 找不到 Scheme

典型错误：

```text
The project does not contain a scheme named ...
```

处理：

```bash
xcodebuild -list -project MyApp.xcodeproj
```

或：

```bash
xcodebuild -list -workspace MyApp.xcworkspace
```

确认 Scheme 名称真实存在，并且 Shared Scheme 已提交到仓库。

### 3. 误用 Project 或 Workspace

如果项目使用 CocoaPods，通常必须构建 `.xcworkspace`，不能继续构建 `.xcodeproj`。

判断：

- 有 `Podfile` 和生成的 Workspace：使用 Workspace。
- 纯 Swift Package Manager：通常使用 Project。
- React Native / Capacitor：通常使用 `ios/*.xcworkspace`。

### 4. Swift Package 下载失败

执行：

```bash
xcodebuild -resolvePackageDependencies \
  -project MyApp.xcodeproj \
  -scheme MyApp
```

检查：

- 依赖地址是否可访问。
- Branch、Tag 或 Commit 是否存在。
- 仓库是否私有。
- Codemagic 是否有私有依赖权限。
- `Package.resolved` 是否锁定了不存在的版本。

### 5. CocoaPods 安装失败

执行：

```bash
cd ios
pod repo update
pod install --repo-update
```

检查 Podfile 的 iOS 最低版本是否与工程和依赖一致。

### 6. `No profiles for ... were found`

这是签名问题，不是源码编译问题。

检查：

- Bundle Identifier。
- Team。
- provisioning profile。
- 证书类型。
- 分发类型。

如果目标只是无签名 IPA，应确认构建命令包含：

```text
CODE_SIGNING_ALLOWED=NO
CODE_SIGNING_REQUIRED=NO
```

### 7. `Signing certificate not found`

检查：

- 证书是否上传到正确的 Codemagic Team。
- `.p12` 是否包含私钥。
- 密码是否正确。
- 证书是否过期或被撤销。
- provisioning profile 是否引用同一证书。

### 8. 无签名 IPA 无法安装

这是预期行为。无签名 IPA 需要重新签名，不能通过反复重打包解决。

### 9. IPA 生成了，但 Artifacts 页面没有

说明 `artifacts` 路径写错。

在构建机中查找：

```bash
find "$CM_BUILD_DIR" -type f -name "*.ipa" -print
```

然后将真实路径加入：

```yaml
artifacts:
  - build/ios/ipa/*.ipa
```

### 10. 只生成 `.app`，没有 IPA

无签名构建需要手动形成标准结构：

```text
Payload/应用名.app
```

然后把 `Payload` 压缩为 `.ipa`。不能直接把 `.app` 改后缀。

### 11. `Archive` 成功但导出失败

通常是签名、ExportOptions、Bundle Identifier 或 provisioning profile 不匹配。查看导出阶段的真实错误，不要只截取最后一句 `ARCHIVE SUCCEEDED`。

### 12. Xcode 版本不支持项目

检查 Codemagic 的 Xcode 版本。项目使用 iOS 26 SDK 时，应选择 Xcode 26.x。不要使用旧 Xcode 16 构建要求 iOS 26 SDK 的项目。

### 13. React Native 构建失败

按顺序检查：

1. Node 版本。
2. `npm ci` / Yarn 安装。
3. CocoaPods。
4. Workspace。
5. Scheme。
6. Hermes 或原生模块的编译错误。

不要一看到 Pod 报错就删除整个 iOS 目录重建。

### 14. Flutter 构建失败

检查：

- Flutter Channel 和版本。
- Dart SDK 约束。
- `flutter pub get`。
- CocoaPods。
- 插件最低 iOS 版本。
- `Runner` 的 Bundle Identifier 和签名配置。

### 15. Capacitor 只有旧网页内容

正确顺序通常是：

```bash
npm ci
npm run build
npx cap sync ios
pod install
```

如果漏掉 Web Build 或 `cap sync ios`，IPA 可能构建成功，但里面还是旧页面。

### 16. 构建成功但应用白屏或闪退

这是运行时问题，不能用“IPA 已生成”掩盖。

检查：

- App 启动日志和崩溃日志。
- Web 资源是否打入包中。
- `Info.plist` 权限声明。
- 动态库是否嵌入。
- 架构是否包含 arm64。
- API 地址、ATS 和 HTTPS。
- 第三方依赖是否在 Release 配置下可用。

### 17. iOS 26 出现弃用警告

先区分 warning 和 error。警告不一定阻止构建。不要为了消除警告就提高最低系统或删除兼容代码。

### 18. 上传 TestFlight 时 Build Number 重复

每次上传必须使用新的 Build Number。可用 Codemagic Build Number 或脚本更新：

```bash
agvtool new-version -all "$BUILD_NUMBER"
```

### 19. GitHub 仓库是私有的

Codemagic 必须获得该私有仓库权限。私有 Swift Package、Submodule 和 Git LFS 也要单独确认访问权限。

### 20. 构建超时

先找耗时步骤：

- Flutter/Node 依赖下载。
- CocoaPods 更新。
- Swift Package 编译。
- 错误的循环脚本。

合理使用 Codemagic Cache，不要只会无脑增加构建时长。

## 十三、安全要求

AI 不能把以下内容提交到 GitHub：

- `.p8` 私钥。
- `.p12` 证书和密码。
- Apple ID 密码。
- GitHub Token。
- Codemagic API Token。
- App Store Connect API 私钥。
- 服务器密码。
- 用户 Cookie。

敏感数据应存放在：

- Codemagic Team integrations。
- Codemagic Environment variables。
- Codemagic Secret groups。

提交前扫描：

```bash
rg -n -i "password|passwd|secret|token|api[_-]?key|private[_-]?key|BEGIN PRIVATE KEY" .
git diff --check
git status --short
```

## 十四、AI 的完整执行流程

```text
收到项目
  ↓
确认是否存在 iOS 工程
  ↓
识别 Native / Flutter / React Native / Capacitor
  ↓
读取真实 Project / Workspace / Scheme / Bundle ID
  ↓
确定无签名或签名 IPA
  ↓
生成根目录 codemagic.yaml
  ↓
校验 YAML、共享 Scheme 和敏感信息
  ↓
提交并推送 GitHub
  ↓
Codemagic 添加仓库并运行 Workflow
  ↓
读取真实构建日志
  ↓
修复错误并重新构建
  ↓
验证 IPA 文件、Payload 结构和签名状态
  ↓
向用户提供 Artifact，并明确安装方式
```

## 十五、可以直接交给 AI 的任务提示词

用户以后制作其他 IPA 时，可以把下面这段和项目一起交给 AI：

```text
请检查这个项目并只使用 GitHub + Codemagic 制作 IPA，我不使用 Mac，也不打开 Xcode。

你需要自行识别它是原生 iOS、Flutter、React Native 还是 Capacitor 项目，找到真实的 Project、Workspace、Scheme、Target、Bundle Identifier 和最低 iOS 版本。

在仓库根目录创建完整可运行的 codemagic.yaml，使用支持 iOS 26 的 Xcode 26.x。没有 Apple 证书时先生成无签名 IPA；如果我提供了 Apple Developer 签名条件，再生成 Development、Ad Hoc 或 App Store IPA。

请提交并推送配置，依据 Codemagic 的真实构建日志持续修复，直到 Artifacts 中出现真实 IPA。最后检查 IPA 不为空、内部包含 Payload/*.app、Info.plist 和可执行文件，并明确告诉我它是否有签名、能否直接安装。

不要把 YAML 校验通过、源码上传、生成 .app 或 ARCHIVE SUCCEEDED 冒充 IPA 已经成功。不要把任何证书、私钥、密码、Cookie 或 Token 提交到 GitHub。
```

## 十六、AI 最终回复模板

```text
已完成 Codemagic IPA 构建：

- 项目类型：原生 iOS / Flutter / React Native / Capacitor
- Workflow：ios-unsigned-ipa
- Xcode：26.4
- 最低 iOS：16.0
- IPA：MyApp-unsigned.ipa
- 文件大小：xx MB
- Payload 结构：已验证
- 签名状态：无签名
- 安装方式：需要 AltStore、SideStore 或开发者证书重新签名
- Codemagic Build：构建链接
- GitHub Commit：提交哈希

仍需真机验证：登录、网络请求、推送、相机、支付或其他依赖真实设备的功能。
```

最重要的规矩：**Codemagic 配置完成、云端编译成功、IPA 真实生成、签名有效、真机功能正常是五件不同的事。AI 必须逐项验证，少他妈拿一条绿色日志糊弄用户。**
