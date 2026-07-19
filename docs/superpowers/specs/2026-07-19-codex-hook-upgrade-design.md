# [peachy-code] Codex Hook 升级设计 Spec（2026-07-19）

## 背景与目标

peachy-code 是一个 macOS 菜单栏 mascot 覆盖层，监听 Claude Code 与 OpenAI Codex CLI 的事件并提供 permission 交互。

**当前问题**（详见 `docs/codex-hook-upgrade-assessment.md`）：
- 对 Claude Code，permission 走官方 hooks 的**双向阻塞连接**——mascot 弹气泡、用户点 allow/deny、决定真正回写给 CC。
- 对 Codex，实现是**日志轮询 + 终端降级**：tail `~/.codex/sessions/*.jsonl`（1 秒轮询）反推事件，permission 靠文本启发式**合成**；用户点 allow/deny 经 `TerminalFallbackTransport` **被丢弃**，只把终端切到前台。决定从不回传给 Codex。
- 根因：代码注释（`CodexEventMapper.swift:473`）建立在"Codex does not emit Claude-style PermissionRequest hooks"的前提上——**该前提已过时**。

**实测确认（codex-cli 0.144.5）**：Codex 已原生支持完整 hooks。二进制 wire schema 与 `--help` 证据：
- 事件名**驼峰**：`PreToolUse` `PostToolUse` `PermissionRequest` `UserPromptSubmit` `SubagentStart` 等（`config.toml` 的 `[hooks.state]` 用小写下划线只是 trust state 的内部 key 派生，配置文件用驼峰）。
- `PreToolUse` 输出 `hookSpecificOutput.permissionDecision` + `permissionDecisionReason`。
- `PermissionRequest` 输出 `hookSpecificOutput.decision.behavior`（`allow`/`deny`）——**与项目现有 `PermissionDecision.httpResponse` 格式完全一致**。
- 存在 **hook trust** 机制（`startup_hooks_review.rs`、"Hooks need review / Trust all and continue"、`--dangerously-bypass-hook-trust`）：新注册的 hook 需用户在 Codex TUI 授权信任后才执行。
- PermissionRequest hook timeout 默认 600 秒、可配，足够人工决策。

**目标**：把 Codex 的 permission 从"假回写"升级为"真双向阻塞"，与 Claude Code 同级；同时修复展开视图对 Codex 显示无效按钮的 UI bug。

## 范围

**纳入**：
1. Codex hook 升级主方案（真 hooks 双向通道）。
2. `ExpandedPermissionView` 对降级 transport 显示无效 Allow/Deny 的 UI bug 修复。

**不纳入**（留待后续）：
- Codex PermissionRequest 的 `updatedInput`/`updatedPermissions`/`textInput` 能力（首版只做核心 allow/deny）。
- 删除日志轮询（保留作降级兜底）。
- Codex Desktop 变体的 hooks 支持验证。

## 架构

```
Codex CLI  ──hook (实时推送)──▶  hook-sender.sh ──HTTP POST /hook──▶ LocalServer
   ▲                                                                      │
   └──────── 403+JSON (decision.behavior) ◀── CodexHookTransport ◀────────┘
                                                （阻塞连接，真回写）

降级兼底：CodexSessionMonitor（日志轮询）+ TerminalFallbackTransport 保留。
去重：某会话真 hooks 送达后，该会话的轮询合成事件静默（会话级 + toolUseId 兜底）。
```

**核心原则：复用而非重写**。Codex 的 hook 契约与 CC 高度一致，因此 `hook-sender.sh`（含阻塞 curl + 403→exit2 回写逻辑）和 `LocalServer` 的 `/hook` 端点几乎零改动即可服务 Codex。升级本质 = 新增一个 installer + 一个 transport + 按 source 分发 + 会话级去重。

## 组件设计

### 单元 1：`CodexHookInstaller`（新增）

仿 `Sources/Services/HookInstaller.swift`。

- **写入目标**：`~/.codex/hooks.json`（JSON，与 CC settings.json 的 hooks 结构一致）。
- **注册事件**（Codex 官方支持 ∩ 项目需要）：`SessionStart` `UserPromptSubmit` `PreToolUse` `PermissionRequest` `PostToolUse` `Stop` `SubagentStart` `SubagentStop` `PreCompact` `PostCompact`（驼峰）。
- **每个事件项**：
  ```json
  { "matcher": "", "hooks": [{ "type": "command", "command": "~/.peachy-code/hooks/hook-sender.sh", "args": ["--source", "codex-cli"], "timeout": 600 }] }
  ```
  `PermissionRequest` timeout 设长（600s）；其余可短。
- **幂等**：install/uninstall/isRegistered 只增删自己那条（command 含 `hook-sender.sh`），保留 AgentPet 等他人 hook。
- **复用** `HookInstaller.ensureScriptExists()` 产出的同一个 `~/.peachy-code/hooks/hook-sender.sh`（已支持 `--source`）。

### 单元 2：`CodexHookTransport`（新增）

仿 `Sources/Adapters/ClaudeCode/HookConnectionTransport.swift`。

- 持有阻塞 `NWConnection`。
- `sendDecision(.allow/.deny)`：回写 `hookSpecificOutput.decision.behavior`——**复用现有 `PermissionDecision.httpResponse`，零改动**。
- **`onRemoteClose`**：连接关闭时触发回调 → 自动 dismiss。这是"TUI 抢答 ↔ peachy 状态"双向同步的关键：用户在 Codex TUI 直接回答 → Codex 杀掉等待中的 hook 进程 → `hook-sender.sh` 的 `trap` 杀 curl → 连接关闭 → `onRemoteClose` → 气泡消失、mascot 状态回落（与 CC 同机制）。
- **capabilities**：`[.permissionResponse]`。⚠️ 首版**不声明** `.updatedInput`/`.updatedPermissions`/`.textInput`——虽然 wire schema 有 `updatedInput` 字段，但未逐一实测，避免声明了却不生效变成新的"假按钮"。

### 单元 3：`CodexAdapter` 改造 + LocalServer 分发

- `LocalServer` 的 `/hook` 端点已对 `permissionRequest` 调 `onPermissionRequest`。**改动仅**：在 `AppStore` 的 `onPermissionRequest` 绑定处，按 event 的 `source` 字段选 transport——CC 事件用 `HookConnectionTransport`，Codex 事件（`source=codex-cli/codex-desktop`）用 `CodexHookTransport`。
- `CodexAdapter.route`（`:58-61`）不再对 permission 硬编码 `TerminalFallbackTransport`——该 transport 仅保留给**轮询降级路径**（那些确无回写连接、只能切终端的合成 permission）。

### 单元 4：会话级去重

- 维护 `sessionsWithLiveHooks: Set<String>`（sessionId）。
- LocalServer 收到**任何** `source=codex-*` 的 hook 事件 → 标记该 sessionId 入集合。
- `CodexAdapter.route` 对**轮询产生的所有事件**（permission 与普通事件）：若 sessionId 已在集合中，**静默丢弃**（真 hooks 会处理，避免活动流与气泡重复）。
- **toolUseId 兜底**：真 hook 首次送达前可能有 ≤1 秒窗口轮询已合成气泡 → 同 `toolUseId` 只保留先到的。
- **清理**：集合项在会话结束（SessionEnd/Stop 后一段时间）或 App 重启时清除。

### 单元 5：UI bug 修复（`ExpandedPermissionView`）

- 现状：`ExpandedPermissionView.body`（`:62-99`）无降级分支，standard 路径一律渲染 Allow/Deny（`:558`/`:577`）。Codex 降级路径（`TerminalFallbackTransport`，仅 `.openTerminal`）下这些按钮无效且误导。
- 修复：比照 `PermissionContentView` 的 `isOpenTerminalFallback`（`:33-41`），加同样分支——**按 capabilities 判断**（非按 source）：
  - transport 有 `.permissionResponse`（含升级后的 `CodexHookTransport`）→ 显示可用的 Allow/Deny。
  - transport 仅 `.openTerminal`（降级 `TerminalFallbackTransport`）→ 显示 "Open Terminal"。
- 一套 capabilities 判断同时覆盖真 hooks 与降级两种情况。

## 数据流

**升级路径（Codex 已授权 trust）**：
1. Codex 触发 permission → 实时执行 `hook-sender.sh --source codex-cli`（PermissionRequest 分支，阻塞 curl）。
2. → `POST /hook`，LocalServer 识别 source=codex + permissionRequest → 建 `CodexHookTransport`（持连接）。
3. sessionId 入 `sessionsWithLiveHooks`。
4. mascot 弹气泡。用户点 allow/deny → `sendDecision` 回写 `decision.behavior` + 对应 HTTP code。
5. `hook-sender.sh` 读 body + exit code → Codex 据此执行/拒绝。
6. （或）用户在 TUI 抢答 → Codex 杀 hook → 连接关闭 → `onRemoteClose` → 气泡自动消失。

**降级路径（未授权 / 旧版本）**：
- 无 hook 事件送达 → sessionId 不入集合 → `CodexSessionMonitor` 轮询照常合成 permission → `TerminalFallbackTransport` → 切终端（旧体验，不中断）。
- 用户在 Codex TUI 授权 trust 后，下个会话真 hook 送达 → 自动升级，无需任何开关。

## 错误处理

- **peachy server 未运行**：`hook-sender.sh` 已有 `/health` 探测，0.3s 超时即退出，不阻塞 Codex。
- **PermissionRequest 超时**（用户不理）：复用现有超时/连接关闭 → auto-dismiss。
- **hooks.json 损坏/不存在**：installer 容错新建（仿 HookInstaller）。
- **trust 未授权**：无事件送达 → 自动走轮询降级，体验不中断。
- **trust 等待期空窗**：由降级路径无缝兜住，不会出现"装了没反应"。

## hook trust 用户交互

- **不自动绕过**（`--dangerously-bypass-hook-trust` 危险，不用）。
- Onboarding / 设置页明确提示："已为 Codex 安装 hook，请在下次打开 Codex 时选择信任（Trust）以启用实时 permission。"
- 授权前 Codex 走轮询降级；授权后自动升级。

## 测试策略

- **单元**：
  - `CodexHookInstaller` install/uninstall/isRegistered 幂等（不误伤他人 hook）。
  - 会话级去重：有/无 live hook 时 permission 与普通事件是否正确静默/透传；toolUseId 兜底。
- **集成**：`CodexHookTransport` 回写 JSON 格式与 exit code 正确性；`onRemoteClose` 触发 auto-dismiss。
- **UI**：capabilities 判断——`.permissionResponse` 显示 Allow/Deny，仅 `.openTerminal` 显示 Open Terminal（紧凑视图 + 展开视图一致）。
- **手动真机联调（验收标准，不可省）**：
  1. peachy 安装 Codex hook → Codex TUI 授权 trust。
  2. 触发真实 permission（如危险命令）→ mascot 弹气泡。
  3. 点 allow/deny → 验证 Codex 真正执行/拒绝。
  4. TUI 抢答 → 验证 peachy 气泡自动消失、mascot 状态回落。
  5. 未授权 trust 时 → 验证自动走终端降级、体验不中断。

## 验收标准

1. Codex 已授权 hook trust 时，permission 走真双向通道：allow/deny 真正生效、实时、可回写。
2. TUI 抢答后 peachy 气泡自动消失、状态同步。
3. 未授权 / 旧版本时自动降级到轮询 + 终端，体验不中断，无重复气泡。
4. 展开视图按 capabilities 正确显示按钮（真 hooks 显示 Allow/Deny，降级显示 Open Terminal）。
5. `swift build` 通过；单元与集成测试通过。

## 风险

- **hook trust UX**：首次需用户手动授权，装完不立即生效——已用降级兜底 + 明确提示缓解。
- **updatedInput 未验证**：首版不做，capabilities 不声明，避免假按钮。
- **Codex Desktop 变体**：`normalizedSource` 区分 codex-cli/codex-desktop，desktop 是否支持 hooks 未验证——首版仅保证 codex-cli，desktop 走降级。
- **双轨去重时序**：≤1 秒窗口用 toolUseId 兜底；需真机验证无重复气泡。
