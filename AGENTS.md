# PeachyPet（macOS 菜单栏应用）— Codex 协作指南

> 目标：让你在不离开编码流的情况下，通过一个漂浮的 mascot（覆盖层）查看 Codex 的会话、权限请求、通知，并进行交互。

## 开发、测试与交付规范

### 工作范围与真实结果

- 修改前检查分支、工作树、已有实现和测试；优先复用同一用户结果的现有入口。保留用户和其他任务的修改，只提交当前任务内容。
- 复杂行为或多步骤依赖先明确目标、边界、验收和实施顺序，复用已有 spec／plan；局部修改直接实施，不为每次任务新建模板、记录目录或 Claim。
- 沿变更的调用方、资源、持久化、平台和发布链路确定影响范围；未知影响、缺失验证和外部阻塞如实记录，不能推定通过。
- 密钥只存 Keychain 或受控凭据环境；测试、日志、截图、报告及提交不得包含密钥或未经脱敏的会话内容。

### Git 与主分支保护

- `main` 是稳定主分支，禁止直接在其上开发、commit 或 push；从已核实的最新主分支创建 `feature/*`，通过 GitHub PR 合入。
- 一个任务一个短期分支，提交前检查暂存 diff；提交标题使用“类型: 中文核心改动”，不附模型署名。不得混入无关改动、擅自 amend、rebase、force push 或丢弃工作。
- `main` 的平台保护应要求 PR、必要 Review 和实际 CI required checks，并禁止强推及删除。不得为了合并关闭保护、跳过检查或使用管理员绕过。
- 本地 commit、远端 push、PR 合并、签名安装和正式发布是不同操作，分别遵循当前任务授权；已有同范围授权不重复询问。
- 合并前核对源 SHA、最新目标 SHA、PR diff 和对应检查结果。源或目标变化时重新判断受影响证据；合并后回读实际合入提交与远端状态。

### 功能与工具行为：测试先行

- 功能、缺陷修复以及脚本／CI 的可执行行为变更采用 Red → Green → Refactor。
- Red：实现前覆盖正常、边界、失败、安全及必要恢复路径，运行目标测试，确认失败来自目标行为缺失；环境损坏、零用例或断言写错不算有效 Red。
- Green：只写满足已确认行为的最小通用实现；禁止弱化断言、使用 skip／only、mock 被测生产实现或针对输入硬编码制造假绿。
- Refactor：目标测试及受影响回归通过后再重构，重构后重新验证受影响范围，保留真实退出码。
- 产品行为以同一用户结果安排单元、集成和原生 E2E；可测试逻辑须有单元测试，跨组件或持久化契约须有集成测试，用户完整流程须有适用的原生 E2E。逐层交代覆盖与结果；结构上不适用时说明原因，缺 runner／账号／环境不等于不适用。
- 工具脚本优先使用临时目录、合成输入或临时 Git 仓库验证，不复制真实用户数据，也不为了测试编排再运行一轮完整产品测试器。
- 纯文档及无可执行行为的说明修改不要求应用测试；验证正文、链接、命令入口和 Git diff 即可。修改可执行配置不能一律归为文档例外。

### 选测、全量与证据复用

- 开发默认只运行当前变更及调用方影响范围内的测试，先查 `Tests/` 中现有用例并使用 `swift test --filter`；不能用“全量绿”替代影响分析。
- 只有用户明确要求全量，或已配置的 PR、受保护 CI、夜间任务、Release 明确规定完整回归时，才运行不带筛选的 `swift test` 或整套原生 E2E。
- 交互式开发准备从增量升级到全量且没有已有明确授权时，先询问“是否运行全量测试？（是／否）”；已配置的非交互 CI 全量门禁按原策略执行，不重复询问，也不得降级。
- 仅在相关源码、测试、资源、夹具、依赖、验证规则、工具及运行环境仍匹配时复用证据；复用数量与本次实际执行数量分开报告。
- 每次交付记录选测依据、实际命令、发现／通过／失败／跳过的用例数、退出码和对应代码或工作树基线；未运行、未评估、外部阻塞及失败都不能计为通过。

### 测试隔离与原生真实性

- 普通测试使用临时目录和独立偏好；保持 `LocalStorage` 的 XCTest 数据隔离，不覆盖真实桌宠、设置、会话、项目、hooks 或服务状态。
- 现有需要真实用户目录、外部程序或服务操作的用例，须先核实隔离与副作用，不能仅因属于 `Tests/` 就当成无副作用的 CI 用例。
- 默认测试不读取用户 Keychain、不请求真实生成服务、不启停用户服务、不注册全局快捷键、不更改系统权限。需要真实依赖的验证按任务授权单独执行，并记录清理结果。
- UI 变更以用户给定设计／截图和明确验收为依据，检查状态切换、布局、可访问性、裁切及用户可见失败恢复。截图须来自实际运行入口；合成预览、模型状态、进程存活均不代替原生界面结果。
- 操作菜单栏、权限或系统外观前记录原状态，结束后恢复并验证。当前支持 macOS 14+；未新增平台契约时，不引入其他平台的强制测试矩阵。

### 已有验证入口

| 入口 | 用途与边界 |
| --- | --- |
| `swift test --filter <测试类或用例正则>` | 目标单元／集成测试；如图标变更可用 `swift test --filter PeachyIconProviderTests`。用例层级由实际内容决定，不由命令名称决定。 |
| `swift build` | 编译检查，不代表打包、安装或原生 UI 验收通过。 |
| `scripts/build-app.sh <输出目录>` | release 构建、资源组装和正式签名；运行前核对签名身份及输出目录，不默认覆盖已安装应用。 |
| `scripts/verify-app-bundle-resources.sh <应用路径>` | 检查独立应用包所需资源；不能代替实际启动、签名和更新验证。 |
| `codesign --verify --deep --strict <应用路径>` | 独立严格验签；失败不能因构建脚本忽略错误而算通过。 |

原生 E2E 复用本次任务已核实可用的入口；尚无共享自动化入口时明确记录，不编造测试命令，不把个人本地脚本写成所有开发者和 CI 已具备的能力。

### GitHub CI 与合并条件

- CI 负责从干净 checkout 验证 PR 的实际变更及与最新 `main` 的临时合并结果；记录源 SHA、目标 SHA、平台、测试范围和产物，普通分支绿不能冒充合并结果绿。
- CI 应覆盖 Swift 编译、与影响匹配的测试和必要的资源／配置检查；不得依赖开发者用户目录、相邻仓库、全局缓存中的手工产物或私人验证脚本。
- 修改 CI 选测、脚本、缓存、失败策略或发布步骤时，须测试其真实行为和失败传播；修改依赖、工具链或测试并发时验证实际 CI 运行形态。
- PR 只在必要检查 `passed` 或有依据的 `not_applicable` 时满足相应条件；`failed`、`not_run`、`not_evaluated`、`external_blocked` 均不是可合并证据，不得打开自动合并绕过缺失验证。
- required checks、Review 和禁止直推只有在 GitHub 配置后才具有服务端强制力；本地测试、文档和人工批准不能代替必需 CI。配置尚未完成时如实报告未接入，不宣称“已受保护”或“CI 通过”。
- 当前核验（2026-11-12）：仓库未配置 GitHub Actions 工作流，`main` 未配置分支保护或 ruleset。本文件先规定要求；接入 CI 和平台保护后须同步更新本段实际状态。

### 安装、发布与升级验收

- 本机安装必须使用打包入口和已核实的正式团队签名；不得用裸二进制或 ad-hoc 签名覆盖应用。保留旧包、真实数据与必要恢复方式。
- 涉及首次启动、资源、签名或打包时，使用本次实际构建的 `.app` 在隔离数据环境验证；开发态启动不能替代安装包验证。
- 涉及自动更新时，分别验证更新源、版本比较、下载、Sparkle 验签、安装、重启和用户数据保留；缺少 Release、签名私钥或实际旧版到新版验证时，不宣称升级可用。
- 公开分发的 Developer ID、公证和 Sparkle 更新包签名与本机开发安装分别验证；合并、构建成功和正式发布是不同结果，不互相替代。

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
- 通过 **Codex 非阻塞 hooks** 监听工具调用、会话、通知等事件（配置写入 `~/.codex/hooks.json`）
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

### Codex hooks → PeachyPet

- 目标：把 Codex 的事件流转为应用内状态与 UI 展示
- hooks 的注册/卸载由 `Sources/Services/CodexHookInstaller.swift` 管理，目标文件是：
  - `~/.codex/hooks.json`
- 不注册 `PermissionRequest`：Codex 审批继续由 Codex 自身的 user / auto_review 设置处理，PeachyPet 不覆盖审批路由

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

**Masko 创作中心采用本地项目包。**
- UI：Dashboard → Peachy → Create
- 项目目录：`~/Library/Application Support/PeachyPet/Mascots/<uuid>/`
- `project.json` 保存草稿、生成任务、验证结果和 Block
- `character/`、`styles/`、`states/`、`transitions/` 保存本地素材
- `.masko` 是带 `manifest.json` 与 SHA-256 清单的可迁移目录包
- 自定义生成 Provider 的 API Key 只存 macOS Keychain，不写入项目或导出包
- Custom API / MCP Bridge 契约见 `docs/masko-creation-center-spec.md`
- 生成后必须通过图片解码、HEVC Alpha 编码、首尾锚点和转场端点检查；失败项进入 Block
- MVP 只自动创建 `Idle <-> 其他状态` 转场，并通过 Any State 路由经 Idle 完成跨状态切换

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
- hooks 的安装策略或 `~/.codex/hooks.json` 结构变更
- 目录结构或关键模块职责发生变化
