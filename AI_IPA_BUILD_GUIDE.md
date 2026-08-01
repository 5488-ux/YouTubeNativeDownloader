# AI 正确编写 Codemagic YAML 并生成 IPA

> 这份文档只解决一件事：让 AI 像本项目的实际制作过程一样，为一个原生 Swift iOS 项目写出能被 Codemagic 执行的 `codemagic.yaml`，并生成无签名 IPA。用户不需要 Mac，也不用打开 Xcode。

## 1. AI 不要直接猜 YAML

写 YAML 之前，必须先从项目中取得 5 个真实值：

```text
PROJECT_FILE   MyApp.xcodeproj
TARGET_NAME    MyApp
TARGET_ID      PBXNativeTarget 前面的 24 位 ID
SCHEME_NAME    MyApp
APP_FILE       MyApp.app
```

这 5 个值必须来自项目文件，不能根据仓库名瞎猜。

本项目当时取得的值是：

```text
PROJECT_FILE   YouTubeNativeDownloader.xcodeproj
TARGET_NAME    YouTubeNativeDownloader
TARGET_ID      500000000000000000000001
SCHEME_NAME    YouTubeNativeDownloader
APP_FILE       YouTubeNativeDownloader.app
```

## 2. 第一步：扫描真实工程

AI 应在仓库根目录执行：

```powershell
rg --files | rg "\.xcodeproj/|\.xcworkspace/|project\.pbxproj$|\.xcscheme$|Package\.swift$|Podfile$"
```

Windows 的 `rg --files` 可能返回反斜杠路径，这是正常的。

必须确认：

- 仓库中确实存在 `.xcodeproj`。
- `.xcodeproj/project.pbxproj` 确实存在。
- 如果存在 `.xcworkspace` 和 `Podfile`，不能继续套本页的 Project 模板，应改用 Workspace 构建。
- 如果只有网页、PHP 或普通 Node 项目，它不是原生 iOS 工程，不能直接生成 IPA。

## 3. 第二步：读取 Target 和产物名

打开：

```text
项目名.xcodeproj/project.pbxproj
```

搜索：

```powershell
rg -n "PBXNativeTarget|productReference|productName|PRODUCT_BUNDLE_IDENTIFIER|IPHONEOS_DEPLOYMENT_TARGET" 项目名.xcodeproj\project.pbxproj
```

典型内容：

```text
500000000000000000000001 /* MyApp */ = {
    isa = PBXNativeTarget;
    name = MyApp;
    productName = MyApp;
    productReference = 20000000000000000000000A /* MyApp.app */;
};
```

由此得到：

```text
TARGET_ID    500000000000000000000001
TARGET_NAME  MyApp
APP_FILE     MyApp.app
```

不要把 `productReference` 的 ID 当成 Target ID。Scheme 的 `BlueprintIdentifier` 必须使用 `PBXNativeTarget` 前面的 ID。

## 4. 第三步：确保存在 Shared Scheme

Codemagic 构建需要 Shared Scheme。文件应位于：

```text
MyApp.xcodeproj/xcshareddata/xcschemes/MyApp.xcscheme
```

如果项目中没有这个文件，AI 必须创建它。下面是完整模板，必须替换 5 处项目值：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2640"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      buildArchitectures = "Automatic">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "TARGET_ID"
               BuildableName = "APP_FILE"
               BlueprintName = "TARGET_NAME"
               ReferencedContainer = "container:PROJECT_FILE">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "TARGET_ID"
            BuildableName = "APP_FILE"
            BlueprintName = "TARGET_NAME"
            ReferencedContainer = "container:PROJECT_FILE">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "TARGET_ID"
            BuildableName = "APP_FILE"
            BlueprintName = "TARGET_NAME"
            ReferencedContainer = "container:PROJECT_FILE">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
```

替换规则示例：

```text
TARGET_ID     → 500000000000000000000001
APP_FILE      → MyApp.app
TARGET_NAME   → MyApp
PROJECT_FILE  → MyApp.xcodeproj
Scheme 文件名 → MyApp.xcscheme
```

替换后，文件中不能残留 `TARGET_ID`、`APP_FILE`、`TARGET_NAME` 或 `PROJECT_FILE`。

## 5. 第四步：在仓库根目录创建 YAML

文件路径必须是：

```text
codemagic.yaml
```

不能放进 `.xcodeproj`、源码目录或 `.github`。

下面就是本项目实际采用的结构。AI 只替换标记为 `REPLACE_...` 的值，不要乱改层级。

```yaml
workflows:
  ios-unsigned-ipa:
    name: iOS Unsigned IPA
    max_build_duration: 60
    instance_type: mac_mini_m2

    environment:
      xcode: 26.4
      vars:
        PROJECT_FILE: "REPLACE_PROJECT_FILE.xcodeproj"
        SCHEME_NAME: "REPLACE_SCHEME_NAME"
        APP_FILE: "REPLACE_APP_FILE.app"
        IPA_FILE: "REPLACE_APP_FILE-unsigned.ipa"

    scripts:
      - name: Verify project and scheme
        script: |
          set -e
          test -d "$CM_BUILD_DIR/$PROJECT_FILE"
          xcodebuild -list \
            -project "$CM_BUILD_DIR/$PROJECT_FILE"

      - name: Resolve Swift packages
        script: |
          set -e
          xcodebuild -resolvePackageDependencies \
            -project "$CM_BUILD_DIR/$PROJECT_FILE" \
            -scheme "$SCHEME_NAME"

      - name: Build unsigned iPhone app
        script: |
          set -e
          xcodebuild clean build \
            -project "$CM_BUILD_DIR/$PROJECT_FILE" \
            -scheme "$SCHEME_NAME" \
            -configuration Release \
            -sdk iphoneos \
            -destination "generic/platform=iOS" \
            -derivedDataPath "$CM_BUILD_DIR/build/DerivedData" \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO

      - name: Package unsigned IPA
        script: |
          set -e
          APP_PATH="$CM_BUILD_DIR/build/DerivedData/Build/Products/Release-iphoneos/$APP_FILE"
          IPA_DIR="$CM_BUILD_DIR/build/ios/ipa"

          test -d "$APP_PATH"
          rm -rf "$IPA_DIR/Payload"
          mkdir -p "$IPA_DIR/Payload"
          cp -R "$APP_PATH" "$IPA_DIR/Payload/"

          cd "$IPA_DIR"
          /usr/bin/zip -qry "$IPA_FILE" Payload
          rm -rf Payload

          test -s "$IPA_DIR/$IPA_FILE"
          unzip -l "$IPA_DIR/$IPA_FILE" | head -50

    artifacts:
      - build/ios/ipa/*.ipa
      - build/DerivedData/Build/Products/Release-iphoneos/*.app
      - /tmp/xcodebuild_logs/*.log
```

## 6. 一个正确替换后的完整例子

假设项目数据为：

```text
PROJECT_FILE  PhotoTool.xcodeproj
SCHEME_NAME   PhotoTool
APP_FILE      PhotoTool.app
```

完整 YAML 应写成：

```yaml
workflows:
  ios-unsigned-ipa:
    name: iOS Unsigned IPA
    max_build_duration: 60
    instance_type: mac_mini_m2

    environment:
      xcode: 26.4
      vars:
        PROJECT_FILE: "PhotoTool.xcodeproj"
        SCHEME_NAME: "PhotoTool"
        APP_FILE: "PhotoTool.app"
        IPA_FILE: "PhotoTool-unsigned.ipa"

    scripts:
      - name: Verify project and scheme
        script: |
          set -e
          test -d "$CM_BUILD_DIR/$PROJECT_FILE"
          xcodebuild -list \
            -project "$CM_BUILD_DIR/$PROJECT_FILE"

      - name: Resolve Swift packages
        script: |
          set -e
          xcodebuild -resolvePackageDependencies \
            -project "$CM_BUILD_DIR/$PROJECT_FILE" \
            -scheme "$SCHEME_NAME"

      - name: Build unsigned iPhone app
        script: |
          set -e
          xcodebuild clean build \
            -project "$CM_BUILD_DIR/$PROJECT_FILE" \
            -scheme "$SCHEME_NAME" \
            -configuration Release \
            -sdk iphoneos \
            -destination "generic/platform=iOS" \
            -derivedDataPath "$CM_BUILD_DIR/build/DerivedData" \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO

      - name: Package unsigned IPA
        script: |
          set -e
          APP_PATH="$CM_BUILD_DIR/build/DerivedData/Build/Products/Release-iphoneos/$APP_FILE"
          IPA_DIR="$CM_BUILD_DIR/build/ios/ipa"

          test -d "$APP_PATH"
          rm -rf "$IPA_DIR/Payload"
          mkdir -p "$IPA_DIR/Payload"
          cp -R "$APP_PATH" "$IPA_DIR/Payload/"

          cd "$IPA_DIR"
          /usr/bin/zip -qry "$IPA_FILE" Payload
          rm -rf Payload

          test -s "$IPA_DIR/$IPA_FILE"
          unzip -l "$IPA_DIR/$IPA_FILE" | head -50

    artifacts:
      - build/ios/ipa/*.ipa
      - build/DerivedData/Build/Products/Release-iphoneos/*.app
      - /tmp/xcodebuild_logs/*.log
```

## 7. YAML 最容易写错的地方

### 错误 1：缩进层级错

正确层级：

```text
workflows
  workflow ID
    environment
      vars
    scripts
      - name
        script
    artifacts
```

全部使用空格，不能使用 Tab。

### 错误 2：`script: |` 后面的命令没有继续缩进

正确：

```yaml
      - name: Build
        script: |
          set -e
          echo "build"
```

错误：

```yaml
      - name: Build
        script: |
        set -e
        echo "build"
```

### 错误 3：把 PowerShell 写进 Codemagic 脚本

Codemagic 的 macOS 构建机默认执行 Shell。脚本中应使用：

```bash
test
rm
mkdir
cp
find
zip
```

不要使用：

```powershell
Test-Path
Remove-Item
New-Item
Copy-Item
```

### 错误 4：错误转义 `$CM_BUILD_DIR`

YAML 中应直接写：

```yaml
script: |
  echo "$CM_BUILD_DIR"
```

不要写成：

```yaml
script: |
  echo "\$CM_BUILD_DIR"
```

### 错误 5：Project 和 Workspace 混用

纯 `.xcodeproj`：

```bash
-project "$CM_BUILD_DIR/MyApp.xcodeproj"
```

CocoaPods `.xcworkspace`：

```bash
-workspace "$CM_BUILD_DIR/MyApp.xcworkspace"
```

这两个参数不能在同一条 `xcodebuild` 命令中同时使用。

### 错误 6：Scheme 名称等于文件夹名

Scheme 必须以 `xcodebuild -list` 的输出或 Shared Scheme 文件为准，不能拿文件夹名、仓库名或 Bundle Identifier 顶替。

### 错误 7：`.app` 路径写错

本模板使用：

```text
build/DerivedData/Build/Products/Release-iphoneos/应用名.app
```

如果构建日志显示产物名不同，必须改 `APP_FILE`，不能继续压缩不存在的路径。

### 错误 8：只把 `.app` 改名成 `.ipa`

IPA 必须具有：

```text
Payload/MyApp.app
```

正确做法是把 `Payload` 文件夹压缩为 ZIP，然后使用 `.ipa` 后缀。

### 错误 9：`artifacts` 指向错误路径

本模板真实输出：

```text
build/ios/ipa/*.ipa
```

Artifacts 必须写同一路径，否则构建可能成功，但 Codemagic 页面没有下载文件。

### 错误 10：误以为无签名 IPA 可以直接安装

这份 YAML 设置了：

```text
CODE_SIGNING_ALLOWED=NO
CODE_SIGNING_REQUIRED=NO
```

生成的是无签名 IPA，需要之后重新签名。

## 8. CocoaPods 项目怎么改

只有项目确实存在 `.xcworkspace` 和 `Podfile` 时才这样改。

在 `environment` 中加入：

```yaml
cocoapods: default
```

在构建前加入：

```yaml
      - name: Install CocoaPods
        script: |
          set -e
          cd "$CM_BUILD_DIR"
          pod install --repo-update
```

然后把所有：

```bash
-project "$CM_BUILD_DIR/$PROJECT_FILE"
```

改为：

```bash
-workspace "$CM_BUILD_DIR/$WORKSPACE_FILE"
```

同时把变量改为：

```yaml
vars:
  WORKSPACE_FILE: "MyApp.xcworkspace"
  SCHEME_NAME: "MyApp"
  APP_FILE: "MyApp.app"
  IPA_FILE: "MyApp-unsigned.ipa"
```

不要在根本没有 Workspace 的项目里硬套这段。

## 9. AI 写完 YAML 后必须做的本地检查

### 9.1 YAML 语法检查

```powershell
npx --yes yaml-lint codemagic.yaml
```

必须看到：

```text
YAML Lint successful
```

### 9.2 检查占位符残留

```powershell
rg -n "REPLACE_|TARGET_ID|TARGET_NAME|PROJECT_FILE|APP_FILE" codemagic.yaml 项目名.xcodeproj\xcshareddata\xcschemes
```

注意：如果 `PROJECT_FILE` 和 `APP_FILE` 是 YAML 中故意使用的变量名，它们可以存在；但它们的值不能仍是 `REPLACE_...`。

重点检查：

```powershell
rg -n "REPLACE_" codemagic.yaml 项目名.xcodeproj\xcshareddata\xcschemes
```

结果必须为空。

### 9.3 Shared Scheme XML 检查

```powershell
python -c "import xml.etree.ElementTree as ET; ET.parse(r'项目名.xcodeproj/xcshareddata/xcschemes/项目名.xcscheme'); print('SCHEME_XML_OK')"
```

### 9.4 Target ID 交叉核对

```powershell
rg -n "PBXNativeTarget|BlueprintIdentifier" 项目名.xcodeproj
```

Scheme 中的 `BlueprintIdentifier` 必须等于 `PBXNativeTarget` 的 ID。

### 9.5 Git 差异检查

```powershell
git diff --check
git status --short
```

## 10. AI 应怎样提交 GitHub

```powershell
git add codemagic.yaml 项目名.xcodeproj\xcshareddata\xcschemes\项目名.xcscheme
git commit -m "ci: add Codemagic unsigned IPA build"
git pull --rebase origin main
git push origin main
```

如果推送提示：

```text
fetch first
```

说明远端有新提交。应执行 `git fetch` 和 `git rebase`，不能使用 `git push --force` 覆盖用户修改。

推送后验证：

```powershell
git rev-parse HEAD
git ls-remote origin refs/heads/main
```

两个提交哈希必须一致。

## 11. Codemagic 中的操作

1. 添加 GitHub 仓库。
2. 选择包含 `codemagic.yaml` 的分支。
3. 点击检查配置文件。
4. 选择 `ios-unsigned-ipa`。
5. 点击开始构建。
6. 先看 `Verify project and scheme`。
7. 再看 `Resolve Swift packages`。
8. 再看 `Build unsigned iPhone app`。
9. 最后看 `Package unsigned IPA`。
10. 在 Artifacts 下载 `.ipa`。

不要只看整个任务变绿。必须确认最后一个打包步骤输出的 ZIP 列表中存在：

```text
Payload/MyApp.app/
Payload/MyApp.app/Info.plist
Payload/MyApp.app/MyApp
```

## 12. 根据构建日志修错

### `The project does not contain a scheme named ...`

原因：Scheme 名称或 Shared Scheme 错。

检查：

```bash
xcodebuild -list -project "$CM_BUILD_DIR/$PROJECT_FILE"
```

### `could not find project ...`

原因：`PROJECT_FILE` 的路径不对。它可能在子目录中，例如：

```yaml
PROJECT_FILE: "ios/MyApp.xcodeproj"
```

### `No such file or directory ... Release-iphoneos/...app`

原因：构建产物名与 `APP_FILE` 不一致。

在 Codemagic 中查找：

```bash
find "$CM_BUILD_DIR/build/DerivedData/Build/Products" -type d -name "*.app" -print
```

然后修改 `APP_FILE` 或 `APP_PATH`。

### `No profiles for ... were found`

无签名模板不应该要求描述文件。检查构建命令是否完整包含：

```text
CODE_SIGNING_ALLOWED=NO
CODE_SIGNING_REQUIRED=NO
```

如果某个依赖 Target 强制签名，需要根据日志对对应 Target 调整，而不是乱填证书。

### Swift Package 解析失败

检查依赖地址、Branch、Tag、Commit 和网络。不要因为 YAML 解析成功就忽略依赖错误。

### 构建成功但 Artifacts 没有 IPA

执行：

```bash
find "$CM_BUILD_DIR" -type f -name "*.ipa" -print
```

若能找到 IPA，修正 `artifacts` 路径；若找不到，检查 `Package unsigned IPA` 是否执行成功。

## 13. AI 最终验证标准

AI 只有同时满足以下条件，才能报告“IPA 已生成”：

- `codemagic.yaml` 通过 YAML Lint。
- Shared Scheme XML 可解析。
- Scheme 的 Target ID 与 `project.pbxproj` 一致。
- GitHub 远端包含 YAML 和 Scheme。
- Codemagic 使用真实 Xcode 26.x 构建。
- `xcodebuild` 返回 0。
- `.app` 目录真实存在。
- `.ipa` 文件真实存在且大小大于 0。
- IPA 内部包含 `Payload/*.app`。
- Codemagic Artifacts 页面能下载 IPA。
- 明确告诉用户它是无签名 IPA，不能直接安装。

Windows 上通过 YAML/XML 检查，只能证明配置格式正确，不能冒充 iOS 编译成功。最终编译必须由 Codemagic 的 macOS/Xcode 构建机完成。

## 14. 可以直接复制给 AI 的提示词

```text
请为这个原生 Swift iOS 项目制作 Codemagic 无签名 IPA 配置。我不用 Mac，也不打开 Xcode。

不要先猜 codemagic.yaml。先读取真实的 .xcodeproj/project.pbxproj，找出 PBXNativeTarget 的 ID、Target 名称、产品 .app 名称、项目文件名和最低 iOS 版本。

确认仓库中存在 Shared Scheme；如果没有，就在 项目名.xcodeproj/xcshareddata/xcschemes/ 下创建完整 xcscheme，并确保 BlueprintIdentifier 等于 PBXNativeTarget 的 ID。

然后在仓库根目录创建完整 codemagic.yaml，使用 Xcode 26.x。依次执行：验证 Project 和 Scheme、解析 Swift Package、使用 iphoneos Release 和 CODE_SIGNING_ALLOWED=NO 构建、把 Release-iphoneos 下的 .app 复制到 Payload、压缩为无签名 IPA，并把 build/ios/ipa/*.ipa 设置为 Artifacts。

写完后必须运行 YAML Lint、XML 解析、Target ID 交叉检查、git diff --check 和敏感信息扫描。提交前不得残留 REPLACE_ 占位符。推送时如果远端有新提交，使用 fetch/rebase，禁止强推覆盖。

最后必须依据 Codemagic 真实日志继续修复，直到 Artifacts 中出现非空 IPA，并检查内部存在 Payload/*.app、Info.plist 和应用可执行文件。不能把 YAML 校验、上传 GitHub、生成 .app 或一条绿色日志冒充 IPA 已成功。
```

一句话总结：**先从 `project.pbxproj` 拿真实值，再建 Shared Scheme，最后按固定层级写 YAML。别让 AI 一上来凭项目名瞎编，十有八九会编出一坨跑不动的 YAML。**
