# PeachyPet（macOS 菜单栏应用）— Claude Code 协作指南

> 目标：让你在不离开编码流的情况下，通过一个漂浮的 mascot（覆盖层）查看 Claude Code 的会话、权限请求、通知，并进行交互。

## TL;DR（常用命令）

- 构建：

```bash
swift build
```

- 运行：

```bash
swift run
```

## 项目概览

PeachyPet 是一个 **macOS 14+ 的 Swift/SwiftUI** 菜单栏应用：
- 通过 **Claude Code hooks** 监听工具调用、会话、通知等事件（配置写入 `~/.claude/settings.json`）
- 应用自身运行一个 **本地 HTTP 服务（默认端口在设置页可配）**，用于接收/分发事件
- UI 包含：覆盖层 mascot、权限气泡、Dashboard、设置页等

## 目录结构（Sources/）

```
Sources/
├── App/             App 入口 & 生命周期
├── Models/          数据模型（会话、事件、动画配置等）
├── Services/        本地 HTTP server、HookInstaller、更新等
├── Stores/          可观察状态（sessions、notifications、mascots…）
├── Views/           SwiftUI 视图（overlay、permission prompt、dashboard、settings）
├── Utilities/       工具方法（LocalStorage、常量等）
└── Resources/       资源（图片/字体/Defaults/*.json）
```

## 关键数据流

### Claude Code hooks → PeachyPet

- 目标：把 Claude Code 的事件流转为应用内状态与 UI 展示
- hooks 的注册/卸载由 `Sources/Services/HookInstaller.swift` 管理，目标文件是：
  - `~/.claude/settings.json`

### Mascot 动画配置（PeachyPet JSON）加载/导入

项目里的 Mascot 配置遵循 `PeachyAnimationConfig`（`Sources/Models/PeachyCollection.swift`）。

**预置 Mascot（presets）加载策略：远端优先，失败回落到本地 bundle。**
- 远端：`MascotStore.fetchRemoteConfig(slug:)` 从 `Constants.peachyBaseURL` 拉取模板 JSON
- 本地回落：`MascotStore.loadBundledConfig(named:)` 读取 bundle 内 `Resources/Defaults/<name>.json`
  - 默认内置配置示例：`Sources/Resources/Defaults/peachy.json`

**用户导入：当前支持“粘贴 JSON 文本导入”，不支持直接选择本地 json 文件路径。**
- UI：Dashboard → “Import JSON”（`Sources/Views/Peachy/PeachyDashboardView.swift`）
- 逻辑：粘贴文本 → decode → `MascotStore.add(config:)`

**持久化：导入/编辑后的 mascots 会写入本机 Application Support。**
- 位置：`~/Library/Application Support/PeachyPet/`
- 文件：`mascots.json`（见 `Sources/Stores/MascotStore.swift` 与 `Sources/Utilities/LocalStorage.swift`）

如果要支持“从本地文件读取 JSON（选择文件/路径覆盖/热更新）”，通常需要：
- 增加文件选择器（SwiftUI `fileImporter` 或 `NSOpenPanel`）
- 为 sandbox/签名场景保存并使用 security-scoped bookmark（避免下次启动失去权限）
- 在 `MascotStore` 增加从 `URL` 读取并 decode 的入口，定义覆盖优先级（本地文件 > 已保存 mascot > bundle > 远端或按需）

## 本地数据与存储位置

- App 数据目录（JSON 持久化）：
  - `~/Library/Application Support/PeachyPet/`
  - 由 `LocalStorage` 管理（`Sources/Utilities/LocalStorage.swift`）

## 代码风格与约束

- 遵循现有 Swift 风格与项目约定
- 使用 SwiftLint（配置在 `.swiftlint.yml`）
- 提交保持聚焦：一个 PR/commit 尽量只做一类改动

## 发布/打包（DMG）

仓库包含 DMG 打包脚本：
- `scripts/create-dmg.sh`：创建带背景图、拖拽到 Applications 的 DMG

## 变更时的更新要求（写给协作代理/未来自己）

当你做了以下任一类改动时，需要同步更新本文件（保持简短、可执行）：
- 新增/修改构建、运行、打包命令
- 新增依赖、工具链要求（Xcode/Swift 版本等）
- Mascot JSON 加载/覆盖策略变化（远端/本地/导入/持久化）
- hooks 的安装策略或 `~/.claude/settings.json` 结构变更
- 目录结构或关键模块职责发生变化
