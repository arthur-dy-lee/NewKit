# NewKit

[English](./README.en.md) · 中文

> 一款 macOS 上的快速新建文件工具，对标 Easy New File。在 Finder 里随手新建 txt / md / py / xlsx / docx / pptx 等任意文件，不用再"打开应用 → 另存为 → 选路径"。1.0.0 起还顺手集成了几个常用系统小工具：反向滚动、防止休眠、立即关闭显示器、浅深主题切换；后续版本加入了 Mos / LinearMouse 风格的鼠标增强：**丝滑滚动**、**线性指针（禁用加速度）**、**鼠标与触摸板独立反向**。

<p align="center">
  <img src="NewKit_1024.png" width="180" alt="NewKit">
</p>

---

## 功能一览

- 📂 **5 个入口**，随你顺手用：菜单栏图标 / 全局快捷键 / Finder 工具栏图标 / Control + 右键 / 系统服务菜单
- 🗂️ **10+ 内置类型**：txt · md · py · js · ts · json · html · css · sh · xlsx · docx · pptx · folder
- 🖥️ **「打开终端」**：所有菜单入口里都可一键在当前 Finder 目录打开 Terminal（可在偏好设置中关闭）
- ⚙️ **完全可配置**：勾选显示、**鼠标拖拽排序**、自定义类型（扩展名 + 图标 + 模板）
- 🧩 **模板变量**：`{{date}} {{time}} {{datetime}} {{year}} {{filename}} {{author}}`
- ⌨️ **全局快捷键**：可自定义、可清空（避开 IDE 冲突，例如 F8）
- 🌐 **中英双语 UI**：默认文件名跟随系统语言（中：`新建文本文档.txt`，英：`Untitled.txt`）
- 🔁 **重名自动追加序号**（`Untitled 2.txt` ...）
- 🔧 **CLI 工具**：`newkit new py ./src` 适合程序员
- 📜 **本地日志**：`~/Library/Logs/NewKit/`，一键导出 zip

### 1.0.0 系统小工具

- 🖱️ **反向滚动**（独立细分）：**鼠标滚轮**和**触摸板 / 妙控鼠标**两组开关分开设置，每组都有垂直 / 水平。基于 CGEventTap，与系统「自然滚动」相互独立。需要辅助功能权限。
- ☕ **防止休眠**：Caffeinated 风格，状态栏菜单一键开关，可选「同时保持屏幕常亮」（基于 IOPMAssertion，无需任何额外权限）
- 🖥️ **立即关闭显示器**：状态栏菜单按钮，一点立刻黑屏，不睡眠系统（封装 `pmset displaysleepnow`）
- 🎨 **主题切换**：浅色 / 深色 / 跟随系统，立即生效，影响整个 App 的 AppKit 控件

### 鼠标增强（Mos / LinearMouse 风格）

- 🌊 **丝滑滚动**（鼠标滚轮）：把 Mac 默认一格一格"咔哒"跳的滚轮替换为像素级、带缓动的连续滚动 — 尤其修好了反向回滚时的顿挫。触摸板和妙控鼠标的手势不受影响；Cmd / Opt / Ctrl / Shift + 滚轮 仍按原始步进处理（保留缩放等功能）。
  - **滚动距离**：一格滚轮对应多少像素（默认 1.00x ≈ 36 px；范围 0.25x – 3.00x）
  - **动画时长**：一格滚动用多长时间漂过去（80 ms 干脆，220 ms 默认像 Mos，600 ms 很漂；范围 80 – 600 ms）
- ➡️ **线性指针**（禁用鼠标指针加速度）：移除 Mac 默认的鼠标加速度曲线，让光标移动呈线性 — 推 1 cm 永远是同样的光标位移，跟 Windows / LinearMouse 一致。**只对鼠标生效**，触摸板加速度保持不变。基于 IOHIDEventSystemClient（私有 API），把每个鼠标的 `HIDPointerAcceleration` 设为 -1。
  - **指针速度**：线性化之后整体的灵敏度（1.0x = 系统当前；1.5x 适合大屏，0.7x 适合精细操作；范围 0.25x – 3.00x）
  - 关闭开关时会还原原始系统设置；启用期间若插入新鼠标，请把开关切换关再打开以应用

---

## 安装

下载最新 DMG：[Releases 页](https://github.com/arthur-dy-lee/NewKit/releases)（占位链接，请替换为实际仓库地址）

1. 双击 `NewKit-x.y.z.dmg`
2. 把 `NewKit` 拖到 `Applications` 文件夹
3. 双击启动 — 应已通过 Apple 公证，无 Gatekeeper 警告

> 如果是从未公证的早期版本下载，且看到「无法验证开发者」，请右键 → **打开**，或运行：
> `sudo xattr -rd com.apple.quarantine /Applications/NewKit.app`

首次启动会显示引导页，按提示授权辅助功能 + 启用 Finder 扩展即可。

---

## 系统权限清单

NewKit 是**纯本地工具**，不联网、不上传任何数据。下表说明每个权限的用途，你可以按需授予：

| 权限 | 用途 | 是否必需 |
|---|---|---|
| **辅助功能（Accessibility）** | 监听 Finder 内的右键事件，让 *Control + 右键* 弹出 NewKit 菜单 | ⚠️ 可选 — 不授权时该入口不可用，其他入口照常 |
| **自动化（Finder）** | 通过 AppleScript 获取最前 Finder 窗口路径、定位文件并触发重命名 | ✅ 强烈推荐 — 不给的话只能落到桌面、且无法自动进入重命名 |
| **完全磁盘访问** | 在受系统保护的目录（如 `~/Library`）内创建文件 | ❌ 一般不需要 |
| **Finder 扩展** | Finder 顶部工具栏的 NewKit 按钮 + 上下文菜单 | ⚠️ 可选 — 启用后多一个入口 |

权限请求是透明的：NewKit 仅在你**首次使用相关入口**时才弹出请求，且可在 *偏好设置 → 权限* 与 *偏好设置 → 关于 → 显示设置引导* 中重新查看与修改。

---

## 入口对照表

| 入口 | 触发方式 | 需要权限 |
|---|---|---|
| 菜单栏图标 | 点击状态栏 `⊞` 图标 | 无 |
| 全局快捷键 + 浮动面板 | 偏好设置中自定义的快捷键 | 无 |
| Finder 工具栏按钮 | 点击 Finder 顶部 NewKit 按钮 | Finder 扩展启用 |
| Finder 系统服务菜单 | 选中文件夹 → 右键 → 服务 → NewKit | 无 |
| Finder Control + 右键 | ⌃ + 右键空白处 | 辅助功能 |

---

## CLI 工具

```bash
# 列出所有已知文件类型
newkit list

# 在当前目录新建 Python 文件
newkit new py

# 在指定目录新建 Markdown 文件
newkit new md ./notes

# 帮助
newkit help
```

CLI 与主 App 共享配置（自定义类型、模板覆盖、作者名）。

---

## 从源码构建

完整说明见 [BUILD.md](./BUILD.md)。简短版：

```bash
brew install xcodegen create-dmg     # 一次性
git clone https://github.com/arthur-dy-lee/NewKit.git
cd NewKit
xcodegen generate
xcodebuild -project NewKit.xcodeproj -scheme NewKit -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/NewKit.app
```

### 打包成 DMG（含公证）

仓库带一键脚本 [`Tools/build_dmg.sh`](./Tools/build_dmg.sh)：

```bash
# 本地玩 / ad-hoc 签名（无需 Apple Developer 账号）
Tools/build_dmg.sh

# 发行：Release 签名 + Apple 公证 + staple
Tools/build_dmg.sh --notarize
```

`--notarize` 需要：
- `Developer ID Application` 证书（导入到 Keychain）
- `xcrun notarytool store-credentials notary-newkit ...` 一次性把 API Key/Issuer ID/App-specific Password 存到 keychain

详细配置参见 [BUILD.md → 签名与公证](./BUILD.md#八签名与公证)。

---

## 开发状态

- ✅ M1 原型：菜单栏 + 5 类型 + Finder 路径
- ✅ M2 MVP：偏好设置 / 注入式右键 / 工具栏图标 / 全局快捷键 / 引导页 / NSServices 兜底
- ✅ M3 V1.0：模板变量 / Office OOXML 空白模板 / 模板覆盖 UI / CLI / 日志导出
- ✅ M4：Developer ID 签名 + Apple 公证 + DMG 打包脚本
- ✅ M5：「打开终端」内置动作 / 文件类型拖拽排序
- ✅ M6 (1.0.0)：反向滚动 / 防止休眠 / 立即关闭显示器 / 浅深主题
- ✅ M7：鼠标增强 — 丝滑滚动 / 线性指针（禁用加速度）/ 鼠标与触摸板反向独立 / 菜单图标随主题自适应
- ⏳ 待办：Sparkle 自动更新、GitHub Releases CI 自动出包

---

## 贡献

欢迎 issue 和 PR。提 PR 前请：
1. `xcodegen generate` 重新生成工程，但**不要**把 `NewKit.xcodeproj/` 提交进 commit
2. 跑一遍 `xcodebuild ... build` 确认编译通过
3. UI 改动请同时更新 `Sources/App/Resources/{en,zh-Hans}.lproj/Localizable.strings`

代码风格：尽量用 `Edit` 工具的最小变更，行内注释只在 *为什么* 不显然时才写。

---

## License

MIT — see [LICENSE](./LICENSE).
