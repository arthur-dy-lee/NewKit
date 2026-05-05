# NewKit

> 一款 macOS 上的快速新建文件工具，对标 Easy New File。在 Finder 里随手新建 txt / md / py / xlsx / docx / pptx 等任意文件，不用再"打开应用 → 另存为 → 选路径"。

---

## 功能一览

- 📂 **5 个入口**，随你顺手用：菜单栏图标 / 全局快捷键 / Finder 工具栏图标 / Control + 右键 / 系统服务菜单
- 🗂️ **10+ 内置类型**：txt · md · py · js · ts · json · html · css · sh · xlsx · docx · pptx · folder
- ⚙️ **完全可配置**：勾选显示、拖拽排序、自定义类型（扩展名 + 图标 + 模板）
- 🧩 **模板变量**：`{{date}} {{time}} {{datetime}} {{year}} {{filename}} {{author}}`
- ⌨️ **全局快捷键**：可自定义、可清空（避开 IDE 冲突，例如 F8）
- 🌐 **中英双语 UI**：默认文件名跟随系统语言（中：`新建文本文档.txt`，英：`Untitled.txt`）
- 🔁 **重名自动追加序号**（`Untitled 2.txt` ...）
- 🔧 **CLI 工具**：`newkit new py ./src` 适合程序员
- 📜 **本地日志**：`~/Library/Logs/NewKit/`，一键导出 zip

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

## 安装与构建

参见 [BUILD.md](./BUILD.md)。简短版：

```bash
brew install xcodegen
cd NewKit
xcodegen generate
xcodebuild -project NewKit.xcodeproj -scheme NewKit -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/NewKit.app
```

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

## 开发状态

- ✅ M1 原型：菜单栏 + 5 类型 + Finder 路径
- ✅ M2 MVP：偏好设置 / 注入式右键 / 工具栏图标 / 全局快捷键 / 引导页 / NSServices 兜底
- ✅ M3 V1.0：模板变量 / Office OOXML 空白模板 / 模板覆盖 UI / CLI / 日志导出
- ⏳ 待办：Sparkle 自动更新、Developer ID 签名 + 公证、DMG 打包

---

## License

MIT — see [LICENSE](./LICENSE).
