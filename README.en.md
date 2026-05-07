# NewKit

English · [中文](./README.md)

> A fast file-creation tool for macOS, inspired by Easy New File. Create txt / md / py / xlsx / docx / pptx / etc. anywhere in Finder — no more "open app → save as → pick path." Starting with 1.0.0, NewKit also bundles a few handy system utilities: reverse scrolling, prevent sleep, sleep displays now, and light/dark theme.

<p align="center">
  <img src="NewKit_1024.png" width="180" alt="NewKit">
</p>

---

## Features

- 📂 **5 entry points**: menu bar icon · global hotkey · Finder toolbar button · Control + right-click · Services menu
- 🗂️ **10+ built-in types**: txt · md · py · js · ts · json · html · css · sh · xlsx · docx · pptx · folder
- 🖥️ **"Open Terminal"**: every menu offers a one-click "open Terminal at current Finder folder" (toggleable in Preferences)
- ⚙️ **Fully configurable**: enable/disable types, **drag-to-reorder**, custom types (extension + icon + template)
- 🧩 **Template variables**: `{{date}} {{time}} {{datetime}} {{year}} {{filename}} {{author}}`
- ⌨️ **Global shortcut**: customizable, clearable (so you can avoid conflicts with IDE shortcuts like F8)
- 🌐 **Bilingual UI**: default filenames follow system language (zh: `新建文本文档.txt`, en: `Untitled.txt`)
- 🔁 **Automatic numeric suffix on collision** (`Untitled 2.txt`, ...)
- 🔧 **CLI**: `newkit new py ./src` for the terminal-inclined
- 📜 **Local logs**: `~/Library/Logs/NewKit/`, one-click zip export

### New in 1.0.0 — system utilities

- 🖱️ **Reverse scrolling**: mouse wheel & trackpad, vertical and horizontal directions toggle independently (CGEventTap-based, requires Accessibility; orthogonal to macOS "Natural scrolling")
- ☕ **Prevent sleep**: Caffeine-style status-bar toggle, with optional "also keep display awake" (IOPMAssertion, no extra permissions)
- 🖥️ **Sleep displays now**: status-bar action — black screen instantly, system stays awake (wraps `pmset displaysleepnow`)
- 🎨 **Theme**: Light / Dark / Follow System, applied app-wide and live

---

## Install

Download the latest DMG from the [Releases page](https://github.com/arthur-dy-lee/NewKit/releases) (replace with the actual repo URL).

1. Double-click `NewKit-x.y.z.dmg`
2. Drag `NewKit` into the `Applications` folder
3. Double-click to launch — the app is notarized by Apple, no Gatekeeper warnings

> If you see "cannot be verified" on an early unnotarized build, right-click → **Open**, or run:
> `sudo xattr -rd com.apple.quarantine /Applications/NewKit.app`

The first launch shows a setup guide that walks you through Accessibility permission and enabling the Finder extension.

---

## Permissions

NewKit is **fully local** — no network, no telemetry. Each permission is requested only when you first use the corresponding feature:

| Permission | Purpose | Required? |
|---|---|---|
| **Accessibility** | Detects right-click events in Finder so *Control + right-click* can pop up the NewKit menu | ⚠️ Optional — without it that one entry is disabled, others still work |
| **Automation (Finder)** | Reads the front Finder window path via AppleScript, locates new files, triggers rename | ✅ Strongly recommended — without it new files fall back to the Desktop and rename can't auto-trigger |
| **Full Disk Access** | Create files inside system-protected dirs (e.g. `~/Library`) | ❌ Usually not needed |
| **Finder Extension** | The NewKit toolbar button + contextual menu in Finder | ⚠️ Optional — adds one more entry point |

You can review and modify everything later under *Preferences → Permissions* and *Preferences → About → Show Setup Guide*.

---

## Entry-point cheatsheet

| Entry | Trigger | Required permission |
|---|---|---|
| Menu bar icon | Click the `⊞` icon in the status bar | None |
| Global shortcut + floating panel | The shortcut you set in Preferences | None |
| Finder toolbar button | Click the NewKit button at the top of Finder | Finder extension enabled |
| Finder Services menu | Select a folder → right-click → Services → NewKit | None |
| Finder Control + right-click | ⌃ + right-click on empty space | Accessibility |

---

## CLI

```bash
# List all known file types
newkit list

# Create a Python file in the current directory
newkit new py

# Create a Markdown file in a specific directory
newkit new md ./notes

# Help
newkit help
```

The CLI shares config (custom types, template overrides, author name) with the main app.

---

## Build from source

Full instructions in [BUILD.md](./BUILD.md). Short version:

```bash
brew install xcodegen create-dmg     # one-time
git clone https://github.com/arthur-dy-lee/NewKit.git
cd NewKit
xcodegen generate
xcodebuild -project NewKit.xcodeproj -scheme NewKit -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/NewKit.app
```

### Packaging a DMG (with notarization)

The repo ships a one-shot script: [`Tools/build_dmg.sh`](./Tools/build_dmg.sh):

```bash
# Local / ad-hoc signing (no Apple Developer account needed)
Tools/build_dmg.sh

# Distribution: Release signing + Apple notarization + staple
Tools/build_dmg.sh --notarize
```

`--notarize` requires:
- A `Developer ID Application` certificate in your Keychain
- A one-time `xcrun notarytool store-credentials notary-newkit ...` to save your API Key / Issuer ID / app-specific password

See [BUILD.md → Signing & Notarization](./BUILD.md#八签名与公证) for the full walkthrough.

---

## Roadmap

- ✅ M1 Prototype: menu bar + 5 types + Finder path detection
- ✅ M2 MVP: Preferences / contextual right-click / toolbar button / global shortcut / onboarding / NSServices fallback
- ✅ M3 V1.0: template variables / blank Office OOXML templates / template-override UI / CLI / log export
- ✅ M4: Developer ID signing + Apple notarization + DMG packaging script
- ✅ M5: "Open Terminal" built-in action / drag-to-reorder file types
- ✅ M6 (1.0.0): reverse scrolling / prevent sleep / sleep displays now / light-dark theme
- ⏳ Planned: Sparkle auto-update / GitHub Releases CI auto-build

---

## Contributing

Issues and PRs are welcome. Before opening a PR:
1. Run `xcodegen generate` to refresh the project, but **don't** commit `NewKit.xcodeproj/`
2. Run `xcodebuild ... build` to confirm it compiles
3. For UI changes, update both `Sources/App/Resources/en.lproj/Localizable.strings` and `Sources/App/Resources/zh-Hans.lproj/Localizable.strings`

Code style: prefer minimal `Edit`-tool diffs; only add inline comments when the *why* isn't obvious from the code.

---

## License

MIT — see [LICENSE](./LICENSE).
