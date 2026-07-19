# [peachy-code] Codex 事件与 Permission 处理链路深度排查 + 升级评估（2026-07-19）

## 摘要（TL;DR）

- **现状**：项目对 Codex 的事件采集是 **tail 日志轮询**（`~/.codex/sessions/*.jsonl`，1 秒间隔）+ 大量**文本启发式合成** permission；permission 决策**根本无法回写给 Codex**——用户点 allow/deny 只是把终端切到前台，让用户自己去终端按键。
- **根因**：这套架构建立在一个**已过时的前提**上——代码注释（`CodexEventMapper.swift:473`）明写 *"Codex does not emit Claude-style PermissionRequest hooks"*。
- **实测反证**：本机 `codex-cli 0.144.5` **原生支持完整 hooks**（含 `--dangerously-bypass-hook-trust`、`[hooks.state]` trust 机制），官方 10 个事件里 `PreToolUse` / `PermissionRequest` **支持双向阻塞回写**，格式与 Claude Code 几乎一致。
- **结论**：Codex 适配可从"日志轮询 + 终端降级"升级为"真 hooks 双向通道"，**与 Claude Code 复用同一套 `hook-sender.sh` 与回写链路**。这是一次**架构对齐**，不是从零重写。
- **另有一个独立的 UI bug**（与升级无关，可立即修）：展开的 permission 视图对 Codex 仍显示无效的 Allow/Deny 按钮。

---

## 一、现状排查（基于代码，带行号）

### 1.1 事件采集层：纯日志轮询

`Sources/Services/CodexSessionMonitor.swift`：
- 数据来源 100% 是 tail `$CODEX_HOME/sessions`（默认 `~/.codex/sessions`）下的 `.jsonl`（`defaultSessionsRoot` 行 11-19）。**无任何主动推送**。
- `pollInterval = 1.0` 秒，`DispatchSourceTimer` 主队列轮询（行 36, 51-57）→ 事件天生带最多 1 秒延迟。
- 按 path 记录 `offset` + `partialLine` 增量读取（行 5-9, 144-193）；文件截断时 offset 归零（行 148-151）。
- Bootstrap 回读尾部 256KB（`bootstrapTailBytes`，15 分钟窗口）会重放历史事件（行 220-232），靠跳过 `.preCompact` 缓解（行 210），但其他历史事件（含合成的 permissionRequest）仍可能重放。

### 1.2 事件映射：`CodexEventMapper.swift`（1076 行）

将 Codex 日志记录类型映射为内部 `HookEventType`。permission 分两类来源：

**直接信号（Codex 日志确有该记录），3 处**：
- `request_user_input`（行 172-187）→ AskUserQuestion permissionRequest
- `request_permissions`（行 249-268）→ permissionRequest
- `exec_approval_request`（行 304-331）→ preToolUse + permissionRequest

**启发式合成（synthesize），3 类判断函数**：
1. `requiresEscalatedPermission`（行 812-815）：仅当 `sandbox_permissions == "require_escalated"`。且 `codexExecApprovalInput`（行 899-901）会**无条件强塞**该字段。
2. `isRequestUserInput`（行 822-825）：工具名为 `request_user_input` 且带 `questions`。
3. `shouldSynthesizeQuestionPermission`（行 817-820）：**最脆弱**——靠 `phase == "commentary"` + `looksLikeQuestionPrompt(message)`（`AgentEvent.swift:98-104`，判定仅 `hasSuffix("?")`）猜测消息是提问。Codex 一旦改 phase 命名即静默失效。

### 1.3 Permission 回写：`TerminalFallbackTransport` 是"假的"

对比两套 transport：

| | Claude Code (`HookConnectionTransport`) | Codex (`TerminalFallbackTransport`) |
|---|---|---|
| 回写通道 | 持有 hook 脚本保活的 `NWConnection`（`:8`），`sendDecision` 写真实 HTTP 响应回该 TCP 连接（`:27-33`） | 只持有一个 `AgentEvent`（`:6`），**无回写通道** |
| `sendDecision` | 把 `decision.httpResponse`（含 `hookSpecificOutput.decision.behavior`）回写，CC 据此真正 allow/deny | **忽略 decision 参数**，allow/deny 都只调 `openTerminal()`（`:17-19`） |
| capabilities | `[.permissionResponse, .textInput, .updatedInput, .updatedPermissions]`（`:10-12`） | `[.openTerminal]`（`:10`），仅此一项 |

`CodexAdapter.route` 在 `.permissionRequest` 时硬编码 `TerminalFallbackTransport`（`CodexAdapter.swift:58-61`）。**用户点 allow 或 deny 效果完全相同**——都只把终端切前台，决定从未传回 Codex，命令是否执行取决于用户随后在终端里实际按的键。

### 1.4 UI 降级：只做了一半

- **紧凑气泡 `PermissionContentView`**：已正确降级。靠 `isOpenTerminalFallback`（`:33-41`）判断，对 Codex 只显示 "Reply in terminal" + "Open Terminal"，**不显示 allow/deny**（`:474-519`）。诚实。
- **展开视图 `ExpandedPermissionView`**：❌ **未降级**。`body`（`:62-99`）无 `isOpenTerminalFallback` 分支，standard 路径一律渲染 Allow/Deny（`:558, :577`）。Codex 用户一旦 ⌘P 展开就看到**无效且误导**的按钮。

---

## 二、官方 Codex hooks 能力（learn.chatgpt.com/docs/hooks + 本机实测）

### 2.1 本机实测证据（codex-cli 0.144.5）

- `codex --help` 有 `--dangerously-bypass-hook-trust`（hook trust 机制存在）
- `~/.codex/config.toml` 有 `[hooks.state]`，记录 `permission_request:0:0` / `pre_tool_use:0:0` / `session_start:0:0` 等 hook 信任状态
- 说明 **Codex 已把 hooks 作为一等公民**，且有 trust 授权流程

### 2.2 官方 10 个事件

`SessionStart` `SubagentStart` `PreToolUse` `PermissionRequest` `PostToolUse` `PreCompact` `PostCompact` `UserPromptSubmit` `SubagentStop` `Stop`

### 2.3 阻塞/回写能力（关键）

- **PreToolUse** 可 deny：stdout `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}`；或 exit 2 + stderr。
- **PermissionRequest** 可 allow/deny：stdout `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow|deny"}}}`。⚠️ 官方明确 **"Don't return updatedInput"**（PermissionRequest 不支持改输入）。
- timeout 默认 **600 秒**、可配 → 足够人工决策。
- 配置支持 `config.toml`（`[[hooks.PreToolUse]]`）或 `hooks.json`。

### 2.4 与项目现有回写格式的契合度

项目 `PendingPermissionStore` 的 `PermissionDecision.httpResponse` 已经在用 `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"/"deny"}}}`——**与 Codex 官方 PermissionRequest 格式完全一致**（因为 CC 和 Codex 这个事件的格式相同）。这意味着回写 JSON **零改动即可复用**。

### 2.5 ⚠️ 头号风险点：事件名大小写

- 官方文档示例：`[[hooks.PreToolUse]]`（驼峰）
- 本机 `config.toml` 的 trust state：`pre_tool_use` / `permission_request`（小写下划线）
- 二者可能是版本差异或双重支持。**升级实现前必须实测确认** Codex 0.144.5 到底认哪种事件名，否则 hook 注册了但不触发。

---

## 三、升级方案评估

### 3.1 核心洞察：这是"复用"不是"重写"

项目已有的 `hook-sender.sh`（`HookInstaller.swift:148-208`）**已经支持 Codex**：
- 已支持 `--source` 参数（`~/.codex/hooks.json` 里历史注册过 `hook-sender --source codex-cli`）
- PermissionRequest 分支已实现阻塞式 `curl` + 读 JSON body + 403→exit 2 的完整回写逻辑
- 回写 JSON 格式已与 Codex PermissionRequest 一致

升级本质 = **给 Codex 建一个类似 `HookInstaller` 的安装器，把同一个 `hook-sender.sh` 注册到 Codex 的 hooks 配置，并让 permission 走真 transport 而非 `TerminalFallbackTransport`**。

### 3.2 要动的文件

| 文件 | 改动 | 复杂度 |
|---|---|---|
| **新增 `CodexHookInstaller.swift`** | 仿 `HookInstaller`，把 `hook-sender.sh` 写入 Codex hooks 配置（`config.toml` 或 `hooks.json`），处理 hook trust | 中 |
| `hook-sender.sh`（`HookInstaller.swift`） | 确认对 Codex 事件名/输入字段兼容；可能需按 `--source` 分支微调 | 低 |
| `CodexAdapter.swift` | permission 事件改用真回写 transport（新建类似 `HookConnectionTransport` 的 Codex 版），不再硬编码 `TerminalFallbackTransport` | 中 |
| **新增 Codex 回写 transport** | 持有 hook 阻塞连接、`sendDecision` 真回写；但 `sendAllowWithUpdatedInput` 要禁用（官方不支持 updatedInput） | 中 |
| `LocalServer.swift` | `/hook` 路由已通用，确认 Codex source 的事件能正确路由（大概率无需改） | 低 |
| `CodexSessionMonitor` / `CodexEventMapper` | **保留作 fallback**（Codex 未授权 hook trust、或旧版本时降级用）；或长期废弃。建议先保留，双轨并行 | 低（保留）|
| `ExtensionInstaller`/设置页 | 增加 Codex hook 的安装/卸载入口与状态显示 | 低 |

### 3.3 风险

1. **事件名大小写不确定**（§2.4）——最高优先级，实现前必须实测。
2. **hook trust**：Codex 有 hook 信任机制，App 自动写入的 hook 首次可能需要用户在 Codex 里授权信任，否则不执行。需验证授权 UX。
3. **双轨冲突**：若同时保留日志轮询 + 新 hooks，同一 permission 可能被双重触发（日志里也会出现 approval 记录）。需要在启用 hooks 时**关闭轮询的 permission 合成路径**，避免重复气泡。
4. **updatedInput 不支持**：Codex PermissionRequest 不能改输入，UI 若提供"编辑后允许"对 Codex 要禁用。
5. **多 IDE/desktop 变体**：`normalizedSource` 区分 codex-cli / codex-desktop，desktop 版是否支持 hooks 待确认。

### 3.4 工作量估计

- 核心链路（安装器 + 回写 transport + adapter 改造）：**中等**，约相当于 CC hook 那套的移植。
- 加上实测大小写、trust UX、双轨去重、UI 降级修复：需要**真机反复联调**（Codex 实际触发 permission 的场景不易构造）。
- 结论：**值得做**（能把 Codex 从"假 permission"升级为和 CC 同级的真体验），但不是一次性小改，需要一个专门的联调迭代。

### 3.5 可立即单独修的小 bug（不依赖升级）

`ExpandedPermissionView` 对 Codex（`isOpenTerminalFallback`）仍显示 Allow/Deny。应比照 `PermissionContentView` 加降级分支，改为 "Open Terminal"。这是**当前就在误导用户**的 bug，可独立修复。

---

## 四、建议的推进顺序

1. **先修 UI 误导 bug**（§3.5）——低成本、立即止损。
2. **实测 Codex 0.144.5 hook 事件名大小写 + trust 流程**（§2.4, §3.3.2）——升级的前置验证，不通过则方案要调整。
3. 验证通过后，再做 `CodexHookInstaller` + 真回写 transport 的完整升级，双轨并行 + 去重。
