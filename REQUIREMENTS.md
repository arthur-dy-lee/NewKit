# NewKit 需求文档

> macOS 上的快速新建文件工具，对标 Easy New File。
> 分发方式：**本地分发**（自签名 + 公证），不走 App Store，以便采用注入式右键增强等更强能力（不受 App Store 沙盒限制）。

---

## 1. 产品定位

帮助 Mac 用户在任意文件夹中**一键新建常用类型的文件**（txt / md / py / xlsx 等），减少"打开应用 → 另存为 → 选择路径"的繁琐流程，并提供可定制的右键菜单增强。

### 目标用户
- 程序员、写作者、学生、办公人群
- 习惯 Windows "右键 → 新建" 后迁移到 Mac，对原生 Finder 的"无法直接新建文件"感到不便的用户

### 核心价值
- **快**：在当前文件夹就地新建，无需打开任何应用
- **可配置**：用户自己决定显示哪些文件类型
- **不挑路径**：不像 Finder Sync Extension 必须勾选监听文件夹

---

## 2. 功能需求

### 2.1 核心功能（MVP）

#### F1. 快速新建文件
- 在当前 Finder 窗口所在文件夹（就是finder中可以和“新建文件夹”平级的地方）创建文件
- **当前文件夹判定**：以**最前 Finder 窗口**所在路径为准；无 Finder 窗口时以桌面为兜底
- **默认文件名**：跟随系统语言自动切换
  - 中文系统：`新建文本文档.txt` / `新建 Markdown 文档.md` / `新建 Python 文件.py` …
  - 英文系统：`Untitled.txt` / `Untitled.md` / `Untitled.py` …
- **重名冲突**：自动追加序号 `Untitled 2.txt` / `Untitled 3.txt`（参照 Finder 原生 "新建文件夹" 行为）
- **创建后行为**：默认仅在 Finder 中高亮 + 进入重命名状态；可在偏好设置中切换为"创建后立即用默认 App 打开"
- 默认支持的文件类型（首批）：
  - `.txt` 文本
  - `.md` Markdown
  - `.py` Python
  - `.js` / `.ts` JavaScript / TypeScript
  - `.json` JSON
  - `.html` HTML
  - `.css` CSS
  - `.sh` Shell 脚本
  - `.xlsx` Excel（空白模板）
  - `.docx` Word（空白模板）
  - `.pptx` PowerPoint（空白模板）
  - 新建文件夹
- 文件创建后：自动定位到该文件，进入重命名状态。一般是在本文件夹下创建文件。

#### F2. 自定义文件类型列表
- 用户可在偏好设置中：
  - 勾选/取消显示的文件类型
  - 调整菜单项顺序（拖拽排序）
  - 添加自定义类型（指定扩展名 + 显示名 + 图标 + 可选模板内容）
  - 删除自定义类型

#### F3. 右键菜单增强
- 在 Finder 右键菜单中加入"NewKit → 新建 ..." 子菜单，可平铺到一级右键
- **实现方案**：基于**辅助功能权限（AXUIElement）+ 监听 Finder 右键事件 + 自绘菜单**
  - 不需要关闭 SIP
  - 不需要往 Finder 进程注入 dylib
  - 与 Easy New File / 超级右键的主流方案一致
- 兜底方案：当用户未授权辅助功能时，自动降级为 `NSServices` 系统服务菜单

#### F4. 触发入口（多入口冗余，互为补充）
- **入口 A**：菜单栏（status bar）图标 → 点击弹出菜单 → 选择类型 → 在当前 Finder 文件夹新建
- **入口 B**：Finder 右键菜单（见 F3）。支持 **注入式右键增强**，可直接平铺到一级右键
- **入口 C**：全局快捷键（用户可配置，例如 `⌃⌥N`）唤起浮动新建面板
  - **必须支持自定义**：用户可任意修改快捷键组合
  - **必须支持取消**：用户可清空快捷键，避免与 IDE / 系统已有快捷键（如 F8）冲突
  - 默认建议使用修饰键组合（避免单一功能键），最终默认值在实现时确认
- **入口 D**：Finder 顶部工具栏图标（通过 Finder Sync Extension 实现）
  - 点击后弹出与菜单栏一致的新建菜单，作用于当前 Finder 窗口路径
  - 通过 `FIFinderSyncController.targetedURL()` 获取当前路径，无需 AppleScript
  - 已知一次性配置成本：用户首次需手动启用扩展并勾选监听根目录（`/Users/<name>` 或整个磁盘）；App 首次启动时提供引导页指引完成
  - 仅作为 UI 扩展使用，不实现同步/角标相关回调

### 2.2 增强功能（V1.1+）

#### F5. 文件模板
- 每种文件类型可配置默认内容模板（如 Python 文件自动写入 `#!/usr/bin/env python3`）
- 支持变量占位符：`{{date}}`、`{{filename}}`、`{{author}}`、`{{year}}`

#### F6. 命名规则
- 默认文件名格式可配置（例如 `untitled`、`未命名`、`新建文件_{{date}}`）
- 同名时自动追加序号（`untitled 2.txt`）

#### F7. 偏好设置面板
- 通用：开机启动、菜单栏图标显示/隐藏、语言（中/英）、**创建后行为（仅高亮重命名 / 立即打开）**
- 文件类型：管理列表（见 F2）
- 模板：编辑每种类型的默认内容（见 F5）
- 快捷键：配置全局快捷键
- 日志：查看本地日志路径、**一键导出日志**（zip 打包到桌面）
- 关于：版本号、检查更新、反馈入口

#### F8. CLI 命令行工具
- 提供 `newkit` 命令行入口，方便程序员在终端使用
- 主 App 安装时自动在 `/usr/local/bin/newkit` 建立软链
- 用法示例：
  - `newkit new py ./src` — 在指定路径新建 Python 文件
  - `newkit new md` — 在当前目录新建 Markdown 文件
  - `newkit list` — 列出已配置的文件类型
- 复用主 App 的文件类型与模板配置（通过 App Group 共享）

### 2.3 不做的功能（明确范围）

- ❌ 不做云同步、文件管理、文件预览
- ❌ 不做删除文件 / 移到废纸篓等扩展操作（严格只做"新建"）
- ❌ 不做配置导入导出（V1.0 阶段）
- ❌ 不上架 Mac App Store（V1.0 阶段，未来可考虑出阉割版双线分发）
- ❌ 不实现 Finder Sync Extension 的同步/角标功能（仅借用其工具栏图标与右键能力作为 UI 扩展）

---

## 3. 非功能需求

### 3.1 兼容性
- macOS 12 (Monterey) 及以上
- 同时支持 Intel 与 Apple Silicon（Universal Binary）

### 3.2 性能
- 启动时间 < 500ms
- 新建文件操作 < 100ms 完成
- 内存占用 < 50MB（后台常驻）

### 3.3 安全与权限
- 代码签名 + 公证（notarization），保证用户首次打开无 Gatekeeper 警告
- **沙盒策略**：**非沙盒**（Developer ID 分发），以支持注入式右键、AppleScript 控制 Finder 等核心能力
- 申请权限透明：仅在首次使用相关功能时请求权限
- 不上传任何用户数据，纯本地工具

#### 系统权限清单（README 中需明确告知用户）

| 权限 | 用途 | 必需 / 可选 |
|---|---|---|
| **辅助功能（Accessibility）** | 监听 Finder 右键事件、自绘右键菜单 | 必需（用于 F3） |
| **自动化（Finder）** | 通过 AppleScript 获取最前 Finder 窗口路径、定位文件并触发重命名 | 必需（用于 F1 / 入口 A） |
| **完全磁盘访问（Full Disk Access）** | 在受系统保护的文件夹（如 `~/Library`）内创建文件 | 可选（绝大多数场景不需要） |
| **Finder 扩展（FinderSync）** | Finder 顶部工具栏图标（入口 D） | 可选（不开启不影响其他入口） |

### 3.4 分发
- 通过官网 / GitHub Releases 提供 `.dmg` 下载
- 自动更新：集成 Sparkle 框架
- **证书与续期**：使用 Apple Developer ID（$99/年），证书有效期 5 年；公证记录永久有效
- **若未来不再续期**：已发布版本永久可用；新版本可降级为自签名（用户首次打开需手动允许）

### 3.5 日志与诊断
- 本地日志路径：`~/Library/Logs/NewKit/`，按日期分文件（保留最近 14 天）
- 偏好设置中提供"导出日志"按钮，一键将日志打包为 zip 输出到桌面

### 3.6 macOS 版本适配运维
- 每年 9 月 macOS 新大版本发布后，需在 1 个月内完成兼容性回归测试
- 重点测试：辅助功能权限行为变化、Finder UI 结构变化（影响 AXUIElement 取菜单位置）、AppleScript 兼容性、Sparkle 自更新

---

## 4. 技术方案（初步）

| 方面 | 选型 |
|---|---|
| 语言 | Swift 6+ |
| UI 框架 | SwiftUI（偏好设置）+ AppKit（菜单栏 / 右键集成） |
| 工程结构 | 主 App target + Finder Sync Extension target（共享 App Group 同步配置） |
| 获取 Finder 当前路径 | 主 App：AppleScript / ScriptingBridge；Extension：`FIFinderSyncController.targetedURL()` |
| 主 App ↔ Extension 通信 | App Group + `UserDefaults(suiteName:)`；必要时用 `NSXPCConnection` |
| 全局快捷键 | `MASShortcut` 或 `KeyboardShortcuts` 库 |
| 自动更新 | Sparkle |
| 签名分发 | Developer ID + notarytool（**非沙盒**） |
| 注入式右键实现 | AXUIElement 监听 Finder 右键事件 + 自绘 NSMenu，**不关闭 SIP**、**不注入 dylib** |
| CLI 工具 | 独立可执行 `newkit`，安装时软链到 `/usr/local/bin/`，与主 App 共享 App Group 配置 |
| 日志 | `os.Logger` + 写入 `~/Library/Logs/NewKit/` |

---

## 5. 里程碑

| 阶段 | 范围 | 预估 |
|---|---|---|
| **M1 原型** | 菜单栏入口 + 5 种文件类型新建 + 获取 Finder 当前路径 | 3–5 天 |
| **M2 MVP** | F1–F4 完整功能（含 Finder 工具栏图标 + 注入式右键 + 偏好设置面板 + 首次启动引导页） | 1–2 周 |
| **M3 V1.0** | F5–F7 + 签名公证 + Sparkle 自更新 + 官网下载页 | 1 周 |
| **M4 V1.1+** | 根据用户反馈迭代：模板市场、更多文件类型、右键方案优化 | 持续 |

---

## 6. 已决策项

| # | 决策点 | 结论 |
|---|---|---|
| 1 | 右键菜单技术路线 | 辅助功能权限 + AXUIElement 监听 Finder + 自绘菜单（不关 SIP、不注入 dylib），未授权时降级 NSServices |
| 2 | Office 空白模板 | 内置最小合法 OOXML（xlsx / docx / pptx 各一份） |
| 3 | 图标资源 | 自绘 |
| 4 | 多语言 | V1.0 即支持中英双语 |
| 5 | 沙盒策略 | 非沙盒，Developer ID 分发 |
| 6 | App Store 上架 | V1.0 不上架；未来可考虑做阉割版双线分发 |
| 7 | 默认文件名 | 跟随系统语言（中："新建文本文档.txt"；英："Untitled.txt"） |
| 8 | 重名冲突 | 自动追加 2 / 3 / 4 序号 |
| 9 | 创建后行为 | 默认仅高亮 + 重命名；偏好设置可切换为"立即打开" |
| 10 | 多 Finder 窗口取路径 | 以最前窗口为准 |
| 11 | 日志 | 本地 `~/Library/Logs/NewKit/`，支持一键导出 zip |
| 12 | macOS 版本适配 | 每年新大版本 1 个月内回归 |
| 13 | 配置导入/导出 | V1.0 不做 |
| 14 | 删除/废纸篓等扩展操作 | 不做 |
| 15 | CLI 工具 | 提供 `newkit` 命令行入口 |
| 16 | 域名 | V1.0 不预订 |

## 6.1 待决策项

- **品牌色与 Logo 设计**：待与设计协作

---

## 7. 验收标准（V1.0）

- [ ] 在任意 Finder 窗口，通过菜单栏图标可在当前文件夹新建至少 10 种类型文件
- [ ] 用户可在偏好设置中自定义显示的文件类型
- [ ] Finder 右键菜单中可见 NewKit 入口（至少通过 NSServices 实现）
- [ ] Finder 顶部工具栏可见 NewKit 图标，点击后弹出新建菜单
- [ ] 首次启动有引导页，指引用户启用 Finder 扩展并勾选监听目录
- [ ] 全局快捷键可用，且可在偏好设置中修改
- [ ] CLI 命令 `newkit` 可用，能复用主 App 配置
- [ ] 偏好设置中可切换"创建后立即打开"开关
- [ ] 偏好设置中可一键导出日志
- [ ] DMG 安装包通过 Apple 公证，首次打开无警告
- [ ] 支持 Intel + Apple Silicon
- [ ] 中英双语 UI（默认文件名跟随系统语言）
- [ ] README 列出完整系统权限清单及用途
