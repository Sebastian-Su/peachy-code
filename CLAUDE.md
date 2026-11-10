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

> ⚠️ **签名铁律**：安装/替换 `/Applications/PeachyPet.app` **必须**经由 `scripts/build-app.sh`（正式 Apple Development 签名）。
> **绝不**用 `codesign --sign -`（ad-hoc）或 `swift build` 的裸二进制覆盖已安装应用——ad-hoc 每次重签 cdhash 都会变，macOS 视其为新应用，导致此前授予的辅助功能（全局快捷键）和通知授权全部失效，只能手动重新授权。
> 脚本已内置硬校验：产物若为 ad-hoc 或缺少 TeamIdentifier 会非零退出。验证签名：`codesign -dvv /Applications/PeachyPet.app`（应显示 `TeamIdentifier=6H93K2UP6T`，而非 `Signature=adhoc`）。

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
        print(s.get('projectName'), s.get('phase'), s.get('agentSource'), s.get('host'), s.get('terminalPid'))
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
- `sessions.json` — session 列表（含 idleUntil、phase、agentSource、host 等）
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
| Session 不消失/一直显示 Running | `sessions.json` 里的 `phase`/`idleUntil`/`host`；`log stream category==session` |
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
   - 注册的 `command` 必须是 `~/.peachypet/hooks/hook-sender.sh --source codex-cli`：Codex 忽略 `args` 字段，参数只能写在命令里。脚本把它写进事件的 `peachy_client` 字段，不改 Codex 自己的 `source`（SessionStart 的开始原因）。旧的「裸命令 + args」注册项在安装时自动迁移
2. **JSONL 轮询（1秒）**：`CodexSessionMonitor` 轮询 `~/.codex/sessions/**/*.jsonl` → `CodexEventMapper` 解析 → `CodexAdapter`

两路通过 `CodexHookLiveness` 去重（hook 到达后标记为 live，抑制 JSONL 轮询的重复事件）。JSONL 通常比 hook 的 SessionStart 早约 3 秒发现新会话，所以已激活会话再收到 SessionStart 只更新状态、不再发通知（`EventProcessor`）。

### 会话来源：引擎与宿主（`docs/session-source-model-design.md`）

- 事件的 `client`（JSON 键 `peachy_client`）标明投递方：Codex hook `codex-cli`、Copilot hook `copilot`、JSONL 轮询 `codex-jsonl`，Claude Code 没有。引擎 `AgentEvent.agentSource` 只看它，不解析 `source`
- `source` 保持代理原值：Claude/Codex hook 的 SessionStart 是开始原因（`startReason`）；JSONL 事件是 rollout 的 session source，另带 `originator`
- 会话的 `agentSource`（引擎）创建时确定不再变；`host`（`SessionHost`）创建时由 `SessionHostResolver` 按顺序确定：Paseo 注册表 → 终端 PID → rollout `originator`（`Codex Desktop`→桌面版，`codex-tui`/`codex_exec`→终端，其他→`other`）
- 宿主只能从 `unknown` 升级为已知值或升级为 `paseo`，后续事件不会降级。图标、跳转、权限卡跳转只读 `host`；`other` 宿主点击不做任何事。`rawSource` 只用于诊断
- `CodexRolloutIndex` 按会话 ID 索引 rollout 文件，`PaseoRegistry` 索引 Paseo 记录，二者未命中都最多 5 秒重扫一次；测试中都指向空目录

### Subagent 状态追踪

- Claude Code 与 Codex 必须成对注册 `SubagentStart` / `SubagentStop`。
- `SessionStore` 按 `sessionId + agentId` 追踪活跃 subagent；session 进入 idle/end 时强制清零，防止漏事件残留。

### 事件处置分类（EventDisposition）

`EventProcessor.process(_:)` 先过滤已识别的 Codex Desktop 后台 startup session，再由 `disposition(for:)` 决定可见事件的下游行为：
- 后台 startup session — 只保留 EventStore 记录，不创建可见 session 或通知，并按 sessionId 抑制后续 Stop/SessionEnd
- `recordOnly` — 只写 EventStore（internalResult、taskCompleted）
- `sessionActivity` — 更新 SessionStore + 可能产生通知
- `userVisibleCompletion` — Stop：Session 进 idle 5 分钟保留期 + 产生完成通知

### Session 生命周期

- **创建**：未被后台 startup 过滤的 sessionActivity 事件到达时若 sessionId 不存在则创建
- **idle 保留期**：Stop 后设置 `idleUntil = now + 5min`，5 分钟后自动 ended
- **等待输入**：Stop 先进入 idle；若 Claude Code 约 60 秒未收到回复并发送 `Notification(idle_prompt)`，session 转为 `waitingInput`，悬浮窗显示限时等待卡。下一次 `UserPromptSubmit` 恢复 running
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

**Masko 创作中心采用本地项目包。**
- UI：Dashboard → Peachy → Create
- 项目目录：`~/Library/Application Support/PeachyPet/Mascots/<uuid>/`
- `project.json` 保存草稿、生成任务、验证结果和 Block
- `character/`、`styles/`、`states/`、`transitions/` 保存本地素材
- `.masko` 是带 `manifest.json` 与 SHA-256 清单的可迁移目录包
- 自定义生成 Provider 的 API Key 只存 macOS Keychain，不写入项目或导出包
- Custom API / MCP Bridge 契约见 `docs/masko-creation-center-spec.md`
- 生成素材必须通过图片解码、HEVC Alpha 编码、首尾锚点和转场端点检查；失败项进入 Block
- MVP 只自动创建 `Idle <-> 其他状态` 转场，并通过 Any State 路由经 Idle 完成跨状态切换

**桌宠资源中心：公开仓库 `Sebastian-Su/peachy-mascots`。**
- 清单是仓库里的 `catalog.json`（`Constants.petCatalogURL`），桌宠包是该仓库的 Release 附件，即 zip：`pet.json` 加上 `media/`，媒体路径相对于包
- 桌宠页「浏览更多」先下载，用 `PetPackInstaller` 校验 SHA-256 并拒绝跳出包外的路径，再解压到 `Application Support/PeachyPet/Pets/<id>/`；`templateSlug` 记为 `pack:<id>`，重装会替换旧的
- 发布：`scripts/publish-pet.sh "<桌宠名>" <pack-id> --version N --upload` 负责打包并上传 Release，再把打印出的条目写进 `catalog.json` 并提交
- 新用户默认桌宠是 PeachMilky（`DefaultPetLoader`）：安装包里只放静态图 `Images/peachmilky-poster.png`，视频走首次下载，失败了可以重试

**精灵图桌宠（spec：`docs/sprite-pet-spec.md`）：一张透明大图加 `pet.json`，即 Codex/petdex 格式。**
- 存成普通桌宠记录：4 个节点和 16 条边照常有，视频为空，另有可选的 `sprite` 字段（来源、标识、图片位置、每个节点播哪几行）。旧版本会忽略这个字段，所以库不会读失败
- 标识是「来源 + 标识」，`templateSlug` 写成 `sprite:<local|openpets|petdex>:<id>`；装在 `Pets/sprites/<来源>/<id>/`，删除时连文件夹一起删。视频桌宠删除时文件保留
- 切图（`SpriteSlicer`）按透明空隙切；标准 8×9 网格上空行不会让后面的行错位。状态对应：待机→第 1 行，工作→第 8、2、3 行每轮随机，求关注→第 7 行，思考→第 9 行；缺的行退回待机
- 桌面播放（`SpriteSheetPlayer`）：每轮结束通知状态机，状态切换等这一轮播完再硬切；整只宠物共用一个缩放，按窗口铺满（不取整数倍），底部居中；整数倍时最近邻放大，否则平滑；帧率工作 8、求关注 4、其他 3
- 「浏览更多」分 PeachyPet / OpenPets / Petdex 三个标签，直接读两站清单（`SpriteCatalog`，缓存在 `SpriteCatalogs/`），不镜像、不转存；只下载用户点的那一只。Petdex 没有缩略图，点「预览」才拉精灵图，存在 `SpritePreviews/`，上限 200 MB，按最久没用的先删
- 发布：`scripts/publish-pet.sh` 也能打包精灵图桌宠（精灵图和待机首帧一起进包），但只限本地导入的；来源是 OpenPets、Petdex 的直接拒绝，不再分发别人的作品
- 切图、逐帧计时器、拉清单的写法复用自 AgentPet（MIT），版权声明在 `ThirdPartyNotices.md`

## 主窗口与皮肤

- 六个入口：收件箱、会话、代理、服务、桌宠、设置。spec 见 `docs/main-window-redesign-spec.md`
- 皮肤：`Skin` / `SkinStore`，选择存在 UserDefaults 的 `skinId`、`skinCustomAccent` 两个键。`Constants` 的颜色都是读当前皮肤的计算属性，新界面直接用 `Constants`，不要写死颜色
- 字体：标题用 Bricolage Grotesque，正文用 Rubik，都放在 `Resources/Fonts`，启动时注册
- 截图和走查用的启动参数（不会保存）：`-initialSection inbox|sessions|agents|services|pets|settings`、`-initialSettingsTab general|shortcuts|notifications|appearance`。`-appLanguage` 会被语言管理器写回设置，用完要恢复。`petCatalogURL` 写进 defaults 可以把清单临时指到本地文件

## 服务页（服务控制台）

- spec：`docs/service-console-spec.md`；注册格式：`docs/service-registry.md` 和 `docs/service-registry.schema.json`，这两份是格式的唯一来源
- 注册：每个服务一个文件，放在 `~/.peachypet/services/<id>.json`；`ServiceStore` 只在页面打开时每秒检查一次目录。用户级 skill `peachypet-service` 的 references 软链接到上面两份文档
- 启动：交给 launchd 临时托管，任务名 `com.peachypet.service.<id>`，任务文件放在 Application Support 的 `ServiceJobs/`，不写 LaunchAgents，所以不会开机自启；停止时用 `launchctl remove` 清理。日志在 `~/Library/Logs/PeachyPet/services/<id>.log`，上限 5 MB
- 首次运行前确认：`ServiceApproval` 把命令、目录、环境变量的指纹存在 UserDefaults 的 `serviceApprovals` 里，三者任何一项变了都要重新确认
- 外部启动识别：`ServiceStatus` 按「端口 + 进程工作目录或命令特征词」匹配；对不上就显示「端口被占用」，不提供停止。停止外部进程前要确认，并且在发信号前再核对一次命令行
- 系统服务（`SystemServices.swift`）：
  - brew 服务和自己的 LaunchAgent 可以操作，启停只用 `launchctl bootout/bootstrap/kickstart`，不调用 `brew services stop`
  - 开机自启只用 `launchctl enable/disable`；未登记的 brew 服务打开开机自启时用 `brew services start`，会同时立即启动
  - 应用自带的 agent 只读；系统 daemon 只显示程序在 `/usr/local` 下的，只读，只给出 sudo 命令供复制，PeachyPet 自己从不执行 sudo

## 本地数据与存储位置

- App 数据目录（JSON 持久化）：
  - `~/Library/Application Support/PeachyPet/`
  - 由 `LocalStorage` 管理（`Sources/Utilities/LocalStorage.swift`）
  - 保存前由 `SecretRedactor` 把 Authorization 和 Bearer 后面的凭据替换成 `<redacted>`
- 启动时会给已开启的集成重新注册 hook，配置内容没变就不写文件（`HookInstaller.fileHasSameJSON`）

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

**Masko 创作中心采用本地项目包。**
- UI：Dashboard → Peachy → Create
- 项目目录：`~/Library/Application Support/PeachyPet/Mascots/<uuid>/`
- `project.json` 保存草稿、生成任务、验证结果和 Block
- `character/`、`styles/`、`states/`、`transitions/` 保存本地素材
- `.masko` 是带 `manifest.json` 与 SHA-256 清单的可迁移目录包
- 自定义生成 Provider 的 API Key 只存 macOS Keychain，不写入项目或导出包
- Custom API / MCP Bridge 契约见 `docs/masko-creation-center-spec.md`
- 生成素材必须通过图片解码、HEVC Alpha 编码、首尾锚点和转场端点检查；失败项进入 Block
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
- hooks 的安装策略或 `~/.claude/settings.json` 结构变更
- 目录结构或关键模块职责发生变化
