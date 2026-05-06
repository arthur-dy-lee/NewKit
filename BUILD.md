# NewKit 构建说明

## 一、依赖

- macOS 13+
- Xcode 16+（实测 Xcode 26.4 / macOS 26.4）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- [create-dmg](https://github.com/create-dmg/create-dmg)：`brew install create-dmg`（仅打包 DMG 时需要）
- Python 3（仅用于一次性生成 Office 空白模板，已生成产物已签入仓库可不再运行）

## 二、生成 Xcode 工程

工程文件 `NewKit.xcodeproj` 由 `project.yml` 自动生成。每次修改 `project.yml` 或新增源文件后重新生成：

```bash
cd /path/to/NewKit
xcodegen generate
```

`NewKit.xcodeproj/` 已被 `.gitignore`，不要提交。

## 三、命令行构建（Debug）

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

`Sources/App/Resources/OfficeTemplates/blank.{xlsx,docx,pptx}` 已生成好并随仓库一起提交。如需重新生成：

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

---

## 八、签名与公证

完整流程已封装到 `Tools/build_dmg.sh`：

```bash
Tools/build_dmg.sh             # ad-hoc 签名 DMG（自用）
Tools/build_dmg.sh --notarize  # Developer ID 签名 + 公证 + staple
Tools/build_dmg.sh --keep-dirty   # 跳过 clean，增量编译
```

下面解释 `--notarize` 模式背后的一次性配置。

### 1. 加入 Apple Developer Program

[https://developer.apple.com/programs/enroll/](https://developer.apple.com/programs/enroll/)（$99/年）。审核通常 24–48 小时。

### 2. 创建 Developer ID Application 证书

1. 打开 [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/add)
2. **Software** 分类下选 **"Developer ID Application"**
3. **Profile Type** 选 **G2 Sub-CA (Xcode 11.4.1 or later)**
4. **Services** 全部不勾
5. 上传 CSR — 用 openssl 一行生成（替代钥匙串助手 GUI）：

   ```bash
   openssl req -new -newkey rsa:2048 -nodes \
     -keyout DeveloperID.key \
     -out    DeveloperID.certSigningRequest \
     -subj   "/emailAddress=YOU@example.com/CN=Your Name/C=US"
   ```

6. 下载得到 `developerID_application.cer`
7. 把 cert + 私钥合并成 .p12 并导入 keychain：

   ```bash
   openssl x509 -in developerID_application.cer -inform DER \
     -out developerID_application.pem -outform PEM

   openssl pkcs12 -export -legacy \
     -inkey DeveloperID.key \
     -in    developerID_application.pem \
     -name  "Developer ID Application: Your Name (TEAMID)" \
     -out   DeveloperID.p12 \
     -password "pass:temp"

   security import DeveloperID.p12 \
     -k ~/Library/Keychains/login.keychain-db -P "temp" -A
   ```

8. 验证：`security find-identity -v -p codesigning` 应能看到 `"Developer ID Application: ..."`

### 3. 创建 App Store Connect API Key（推荐）或 App-Specific Password

**API Key（推荐，长期有效，可脚本化）**

1. 打开 [App Store Connect → Users and Access → Integrations](https://appstoreconnect.apple.com/access/integrations/api)
2. 创建 Key，Access 选 **Developer**
3. 下载 `AuthKey_XXXXXXXXXX.p8`，妥善保管（只能下载一次）
4. 记录页面顶部的 **Issuer ID**（UUID 格式）和 **Key ID**（10 位，文件名中间那段）

**或者 App-Specific Password（更简单）**

1. 打开 [Apple ID → 登录与安全 → 应用专用密码](https://account.apple.com/account/manage)
2. 生成新密码并复制

### 4. 把凭证存进 Keychain（一次性）

**用 API Key**：

```bash
xcrun notarytool store-credentials notary-newkit \
  --key /path/to/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX \
  --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**用 App-Specific Password**：

```bash
xcrun notarytool store-credentials notary-newkit \
  --apple-id "you@example.com" \
  --team-id  "TEAMID" \
  --password "abcd-efgh-ijkl-mnop"
```

profile 名 `notary-newkit` 与 `Tools/build_dmg.sh` 默认一致；要换名通过环境变量：`NOTARY_PROFILE=other-name Tools/build_dmg.sh --notarize`。

### 5. 改 `project.yml`

把 `CODE_SIGN_IDENTITY` 改成完整的 Developer ID 名称：

```yaml
settings:
  base:
    CODE_SIGN_IDENTITY: "Developer ID Application: Your Name (TEAMID)"
```

`project.yml` 已为 Release 配置了：
- `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` — 去掉 `get-task-allow` 调试 entitlement
- `OTHER_CODE_SIGN_FLAGS: --timestamp` — 加 Apple TSA 安全时间戳

这两项是公证必须的，缺任一都会被 `notarytool` 拒收。

### 6. 一键打包

```bash
Tools/build_dmg.sh --notarize
```

脚本会：
1. `xcodegen generate`
2. Release 构建
3. zip → 提交 app 公证 → wait → staple
4. `create-dmg` 打 DMG
5. 提交 DMG 公证 → wait → staple

公证通常 1–10 分钟一次，繁忙时可能更久。最终产物：`dist/NewKit-<version>.dmg`，**双击直接能用，无 Gatekeeper 警告**。

### 7. 排错速查

| 现象 | 原因 | 解法 |
|---|---|---|
| `notarytool submit` 返回 `Invalid` + `not signed at all` | 证书不是 Developer ID Application | 检查 `security find-identity -v -p codesigning` |
| `Invalid` + `does not include a secure timestamp` | 缺 `--timestamp` flag | 见上面第 5 步 |
| `Invalid` + `requests the com.apple.security.get-task-allow entitlement` | Debug entitlement 没剥掉 | 见上面第 5 步 |
| `stapler staple` 报 `Record not found` | 公证还没真的 Accepted | 用 `notarytool log <id> --keychain-profile notary-newkit` 看具体错误 |

### 8. Sparkle 自动更新（待集成）

待集成步骤：
1. `project.yml` 加入 `Sparkle` 包依赖
2. 主 App 启动时初始化 `SPUStandardUpdaterController`
3. 生成 Sparkle EdDSA 签名密钥并把公钥写入 Info.plist
4. 在 GitHub Pages / 自建空间发布 `appcast.xml`

---

## 九、清理

```bash
rm -rf build dist NewKit.xcodeproj
```
