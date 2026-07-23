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

- 编译 release 并安装：

```bash
bash scripts/build-app.sh dist
pkill -x PeachyPet 2>/dev/null; sleep 1
rm -rf /Applications/PeachyPet.app
cp -R dist/PeachyPet.app /Applications/PeachyPet.app
```

## 调试：日志与崩溃堆栈

### OSLog 日志（PeachyLog）

所有结构化日志通过 `Sources/Utilities/PeachyLog.swift` 统一写入系统日志，subsystem = `com.peachy.pet`。

**实时查看（最常用）：**

```bash
# 全部日志
log stream --predicate 'subsystem == "com.peachy.pet"' --level debug

# 只看 session 生命周期
log stream --predicate 'subsystem == "com.peachy.pet" AND category == "session"'

# 只看 Codex JSONL 解析
log stream --predicate 'subsystem == "com.peachy.pet" AND category == "codex"'

# 只看事件处理
log stream --predicate 'subsystem == "com.peachy.pet" AND category == "event"'
```

**查历史日志：**

```bash
# 过去1小时全部
log show --predicate 'subsystem == "com.peachy.pet"' --last 1h --level debug

# 只看 warning/error
log show --predicate 'subsystem == "com.peachy.pet"' --last 1h --level error
```

**Log categories 对应内容：**

| category | 覆盖内容 |
|----------|---------|
| `session` | session 创建/结束/idle过期/interrupt检测/startup迁移/internal turn rollback |
| `event` | 每个事件处理入口（hookEventName/sid/src）、internalResult rollback |
| `codex` | JSONL 每条事件、internalResult schema 识别（approval/exclude/suggestions） |
| `permission` | 权限请求处理 |
| `lang` | 语言切换、.lproj 加载结果 |
| `network` | 本地 HTTP server 相关 |
| `ui` | 覆盖层状态机 |

**Console.app 快速过滤：** 打开 Console.app → 搜索栏输入 `com.peachy.pet`

### 持久化数据文件（无需 log 可直接查）

```bash
# 查看所有 active session 状态
python3 -c "
import json,os
path=os.path.expanduser('~/Library/Application Support/PeachyPet/sessions.json')
sessions=json.load(open(path))
for s in sessions:
    if s.get('status')=='active':
        print(s.get('projectName'), s.get('phase'), s.get('rawSource'), s.get('terminalPid'))
"

# 查看最近100条事件
python3 -c "
import json,os
path=os.path.expanduser('~/Library/Application Support/PeachyPet/events.json')
events=json.load(open(path))
for e in events[-20:]:
    print(e.get('hookEventName'), e.get('sessionId','')[:20], e.get('source'))
"
```

数据文件位置：`~/Library/Application Support/PeachyPet/`
- `sessions.json` — session 列表（含 idleUntil、phase、rawSource 等）
- `events.json` — 最近 1000 条事件（activity feed）
- `notifications.json` — 通知历史

### 崩溃堆栈

```bash
# 查看最近崩溃报告
ls ~/Library/Logs/DiagnosticReports/ | grep -i peachy | tail -5

# 打开最新崩溃报告
open ~/Library/Logs/DiagnosticReports/$(ls -t ~/Library/Logs/DiagnosticReports/ | grep -i peachy | head -1)

# 或通过 Console.app：左侧 "Crash Reports" → 搜索 PeachyPet
```

崩溃报告包含完整堆栈、线程状态、寄存器。关键字段：
- `Exception Type` — 崩溃类型（SIGABRT/EXC_BAD_ACCESS 等）
- `Exception Subtype` — 具体原因
- `Thread N Crashed` — 崩溃线程的完整调用栈

### 常见问题排查思路

| 症状 | 先查哪里 |
|------|---------|
| Session 不消失/一直显示 Running | `sessions.json` 里的 `phase`/`idleUntil`/`rawSource`；`log stream category==session` |
| 事件没有触发 UI 更新 | `log stream category==event`；确认 hookEventName 是否到达 |
| Codex 任务状态异常 | `log stream category==codex`；看 JSONL 文件 `~/.codex/sessions/` |
| 通知重复/不显示 | `notifications.json`；`log stream category==event` 看 disposition |
| 语言切换不生效 | `log stream category==lang`；看 .lproj 是否加载成功 |
| App 崩溃 | `~/Library/Logs/DiagnosticReports/` 或 Console.app |

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
├── Utilities/       工具方法（LocalStorage、PeachyLog、LanguageManager、常量等）
└── Resources/       资源（图片/字体/Defaults/*.json、en.lproj/zh.lproj 本地化）
```

## 关键数据流

### Claude Code hooks → PeachyPet

- 目标：把 Claude Code 的事件流转为应用内状态与 UI 展示
- hooks 的注册/卸载由 `Sources/Services/HookInstaller.swift` 管理，目标文件是：
  - `~/.claude/settings.json`
- Settings → Tools 中 Claude Code / Codex / 各 IDE 均用安装 Toggle；关闭 Claude Code 或 Codex 后会持久化偏好，应用下次启动不会自动重新安装对应 hooks。

### Codex 事件 → PeachyPet（双路径）

1. **Hook 路径（实时）**：Codex 触发 `~/.codex/hooks.json` 里的 hook-sender.sh → POST `/hook` → `LocalServer` → `CodexAdapter`
2. **JSONL 轮询（1秒）**：`CodexSessionMonitor` 轮询 `~/.codex/sessions/**/*.jsonl` → `CodexEventMapper` 解析 → `CodexAdapter`

两路通过 `CodexHookLiveness` 去重（hook 到达后标记为 live，抑制 JSONL 轮询的重复事件）。

### Subagent 状态追踪

- Claude Code 与 Codex 必须成对注册 `SubagentStart` / `SubagentStop`。
- `SessionStore` 按 `sessionId + agentId` 追踪活跃 subagent；session 进入 idle/end 时强制清零，防止漏事件残留。

### 事件处置分类（EventDisposition）

`EventProcessor.disposition(for:)` 决定每个事件的下游行为：
- `recordOnly` — 只写 EventStore（internalResult、taskCompleted）
- `sessionActivity` — 更新 SessionStore + 可能产生通知
- `userVisibleCompletion` — Stop：Session 进 idle 5 分钟保留期 + 产生完成通知

### Session 生命周期

- **创建**：任何 sessionActivity 事件到达时若 sessionId 不存在则创建
- **idle 保留期**：Stop 后设置 `idleUntil = now + 5min`，5 分钟后自动 ended
- **无 Stop 的 idle**：JSONL 轮询产生的 session 无法保证收到 Stop，`expireIdleSessions` 用 `lastEventAt + 5min` 作隐式过期
- **内部 turn 回滚**：Codex 审批 turn（`internalResult`）通过 snapshot 机制回滚，不留幽灵 session

### Mascot 动画配置（PeachyPet JSON）加载/导入

项目里的 Mascot 配置遵循 `PeachyAnimationConfig`（`Sources/Models/PeachyCollection.swift`）。

**预置 Mascot（presets）加载策略：远端优先，失败回落到本地 bundle。**
- 远端：`MascotStore.fetchRemoteConfig(slug:)` 从 `Constants.peachyBaseURL` 拉取模板 JSON
- 本地回落：`MascotStore.loadBundledConfig(named:)` 读取 bundle 内 `Resources/Defaults/<name>.json`
  - 默认内置配置示例：`Sources/Resources/Defaults/peachy.json`

**用户导入：当前支持"粘贴 JSON 文本导入"，不支持直接选择本地 json 文件路径。**
- UI：Dashboard → "Import JSON"（`Sources/Views/Peachy/PeachyDashboardView.swift`）
- 逻辑：粘贴文本 → decode → `MascotStore.add(config:)`

**持久化：导入/编辑后的 mascots 会写入本机 Application Support。**
- 位置：`~/Library/Application Support/PeachyPet/`
- 文件：`mascots.json`（见 `Sources/Stores/MascotStore.swift` 与 `Sources/Utilities/LocalStorage.swift`）

## 本地数据与存储位置

- App 数据目录（JSON 持久化）：
  - `~/Library/Application Support/PeachyPet/`
  - 由 `LocalStorage` 管理（`Sources/Utilities/LocalStorage.swift`）

## 国际化（i18n）

- 语言切换由 `Sources/Utilities/LanguageManager.swift` 管理（`@Observable` 单例）
- 字符串文件：`Sources/Resources/en.lproj/Localizable.strings` 和 `zh.lproj/`
- 全局取值函数：`t("key")`，fallback 返回 key 本身不崩溃
- SPM 资源打包在 `PeachyPet_PeachyPet.bundle` 子目录，`LanguageManager` 会自动搜索
- 不做翻译的页面：`OnboardingView`、`PeachyDashboardView`、`MascotDetailView`

## 代码风格与约束

- 遵循现有 Swift 风格与项目约定
- 使用 SwiftLint（配置在 `.swiftlint.yml`）
- 提交保持聚焦：一个 PR/commit 尽量只做一类改动

## 发布/打包（DMG）

仓库包含 DMG 打包脚本：
- `scripts/create-dmg.sh`：创建带背景图、拖拽到 Applications 的 DMG
- `scripts/build-app.sh`：编译 release + 组装 .app bundle + 签名

## 变更时的更新要求（写给协作代理/未来自己）

当你做了以下任一类改动时，需要同步更新本文件（保持简短、可执行）：
- 新增/修改构建、运行、打包命令
- 新增依赖、工具链要求（Xcode/Swift 版本等）
- Mascot JSON 加载/覆盖策略变化（远端/本地/导入/持久化）
- hooks 的安装策略或 `~/.claude/settings.json` 结构变更
- 目录结构或关键模块职责发生变化
- 新增 log category 或修改 subsystem
- 国际化语言新增或 key 命名规范变化


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
