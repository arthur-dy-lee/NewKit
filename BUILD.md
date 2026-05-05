# NewKit 构建说明

## 一、依赖

- macOS 13+
- Xcode 16+（实测 Xcode 26.4 / macOS 26.4）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- Python 3（仅用于一次性生成 Office 空白模板，已生成产物已签入仓库可不再运行）

## 二、生成 Xcode 工程

工程文件 `NewKit.xcodeproj` 由 `project.yml` 自动生成。每次修改 `project.yml` 或新增源文件后重新生成：

```bash
cd /Users/arthur.lee/codes/NewKit
xcodegen generate
```

## 三、命令行构建

```bash
# 主 App
xcodebuild -project NewKit.xcodeproj -scheme NewKit \
  -configuration Debug -derivedDataPath build build

# CLI 工具
xcodebuild -project NewKit.xcodeproj -scheme newkit \
  -configuration Debug -derivedDataPath build build
```

产物位置：
- 主 App：`build/Build/Products/Debug/NewKit.app`
- CLI：`build/Build/Products/Debug/newkit`
- Finder Extension：自动嵌入主 App 的 `Contents/PlugIns/NewKitFinderExtension.appex`

## 四、运行

```bash
open build/Build/Products/Debug/NewKit.app

# 把 CLI 软链到 PATH（可选）
sudo ln -sf "$(pwd)/build/Build/Products/Debug/newkit" /usr/local/bin/newkit
```

启动后菜单栏会出现 `⊞` 图标。首次启动会显示引导页指引授权。

## 五、Office 空白模板（一次性生成）

`Sources/App/Resources/OfficeTemplates/blank.{xlsx,docx,pptx}` 已经生成好并随仓库一起提交。如果需要重新生成：

```bash
python3 Tools/build_office_templates.py
```

## 六、Xcode 中开发

```bash
open NewKit.xcodeproj
```

⌘R 直接运行调试。

## 七、Targets 总览

| Target | Bundle ID | 类型 |
|---|---|---|
| `NewKit` | `app.newkit.NewKit` | macOS App（非沙盒） |
| `NewKitFinderExtension` | `app.newkit.NewKit.FinderExtension` | Finder Sync Extension（沙盒） |
| `newkit` | `app.newkit.cli` | 命令行工具 |

## 八、签名与发布（待办，需 Apple Developer ID）

以下步骤需要付费的 Apple Developer Program 账户。Debug 构建当前用 `-`（ad-hoc）签名即可本地运行。

### 1. 配置开发者账号

在 `project.yml` 把 `DEVELOPMENT_TEAM` 改成你的 10 位 Team ID，并把 `CODE_SIGN_IDENTITY` 改成 `"Developer ID Application"`。

### 2. 公证流程

```bash
# 1. Release 构建
xcodebuild -project NewKit.xcodeproj -scheme NewKit \
  -configuration Release -derivedDataPath build clean build

# 2. 打成 zip 提交公证
ditto -c -k --keepParent build/Build/Products/Release/NewKit.app /tmp/NewKit.zip
xcrun notarytool submit /tmp/NewKit.zip \
  --apple-id "you@example.com" \
  --team-id "XXXXXXXXXX" \
  --password "@keychain:notary-password" \
  --wait

# 3. Staple 公证票据
xcrun stapler staple build/Build/Products/Release/NewKit.app

# 4. 打 DMG（可选，用 create-dmg 之类的工具）
```

### 3. Sparkle 自动更新（待集成）

待集成步骤：
1. `project.yml` 加入 `Sparkle` 包依赖
2. 主 App 启动时初始化 `SPUStandardUpdaterController`
3. 生成 Sparkle EdDSA 签名密钥并把公钥写入 Info.plist
4. 在 GitHub Pages / 自建空间发布 `appcast.xml`

## 九、清理

```bash
rm -rf build NewKit.xcodeproj
```
