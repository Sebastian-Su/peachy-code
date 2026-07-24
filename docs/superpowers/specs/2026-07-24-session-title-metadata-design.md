# SessionSwitcher 会话标题与项目名称设计

## 背景

SessionSwitcher 当前只显示 session 的项目目录名与运行状态。Codex Desktop、Codex CLI 和 Claude Code 都存在用户可识别的会话名称，但数据来源不同：

- Codex CLI/Desktop 的正式会话标题保存在 `~/.codex/session_index.jsonl` 的 `thread_name`。
- Claude Code `/rename` 在 session transcript 中追加 `type: "custom-title"` 与 `customTitle`。
- Codex Desktop 的手动项目名保存在 `~/.codex/.codex-global-state.json` 的 `local-projects`，通过 `thread-project-assignments` 与 threadId 关联。
- Claude Code 与短暂 Codex session 可能没有正式标题，只能使用首条用户任务作为回退。
- iTerm2/终端窗口标题只是展示状态，不是稳定的 agent 会话契约。

## 目标

在 SessionSwitcher 第一行显示 `项目显示名 · 会话标题`，并在 provider 改名后 1–2 秒内近实时更新。

## 数据模型

`AgentSession` 增加三个可编码字段：

- `sessionTitle: String?`：provider 提供的正式会话标题。
- `projectDisplayName: String?`：Codex Desktop 手动项目名称覆盖。
- `firstUserPrompt: String?`：没有正式标题时的稳定回退。

显示优先级：

### 项目显示名

1. `projectDisplayName`
2. `projectName`
3. `projectDir` 的 basename
4. `Session`

### 会话标题

1. `sessionTitle`
2. `firstUserPrompt`
3. 不显示标题与分隔符

正式标题更新不修改 `firstUserPrompt`；删除或读取失败时保留最近一次有效正式标题。

## Metadata 数据源

### Claude Code

- `UserPromptSubmit` hook 解码 `prompt`，首次非空值写入 `firstUserPrompt`。
- 监听该 session 的 transcript JSONL。
- 遇到 `type: "custom-title"` 时读取 `customTitle`。
- 同一 session 重复 `/rename` 时最后一条 `custom-title` 生效。
- Claude 自动生成的 slug 不作为人类标题。

### Codex CLI / Desktop

- 从 Codex JSONL 的第一条 `user_message` 获取 `firstUserPrompt`。
- 增量读取 `~/.codex/session_index.jsonl`。
- `id == AgentSession.id` 的最新 `thread_name` 写入 `sessionTitle`。
- CLI 与 Desktop 使用同一套 thread title 映射。
- 短暂、未进入 session index 的 Codex session 继续使用首条用户任务回退。

### Codex Desktop 项目名称

- 检查 `~/.codex/.codex-global-state.json` 的修改时间。
- 从 `thread-project-assignments[sessionId].projectId` 获取 projectId。
- 从 `local-projects[projectId].name` 获取 `projectDisplayName`。
- Desktop 手动项目名优先于 cwd basename，但不覆盖 `sessionTitle`。
- 文件可能原子替换，因此监听父目录并在变化后重新读取完整文件。

## SessionMetadataMonitor

新增 `SessionMetadataMonitor` 服务：

- 每 1 秒检查一次活跃 session 的 metadata。
- 对 append-only JSONL 维护文件 offset，只解析新增记录。
- 对 Codex global state 使用 mtime，变化时完整重读。
- 只处理 `SessionStore.activeSessions`，不扫描全部历史 session。
- 通过 sessionId 回调 SessionStore 更新 metadata。
- AppStore 启动时启动 monitor，停止时关闭 timer/文件监听。
- App 启动后先使用 `sessions.json` 中已持久化值，再异步刷新 provider metadata。

## SessionStore 更新规则

SessionStore 提供按 sessionId 更新 metadata 的入口：

- 只有新值非空且与旧值不同时才持久化。
- `firstUserPrompt` 只写一次，不被后续用户消息覆盖。
- `sessionTitle` 和 `projectDisplayName` 可随改名更新。
- metadata 更新触发 SessionSwitcher 观察者刷新，但不改变 session status、phase、lastEventAt 或排序。
- metadata 文件损坏、暂时不存在或无法读取时保留已有值。

## SessionSwitcher UI

第一行格式：

```text
namiwork-core · 解决 release 分支冲突
```

第二行保持现状：

```text
Running · now
```

UI 规则：

- 项目显示名与会话标题在同一行。
- 使用 ` · ` 分隔。
- 没有标题时只显示项目名，不显示空分隔符。
- 第一行保持单行截断，不增大列表宽度或行高。
- 标题更新时列表原地刷新，不关闭 SessionSwitcher，不改变当前选中项。
- 图标、状态点、快捷键、相对时间与 subagent 指示器保持不变。

## 错误处理

- 不解析终端/iTerm2 窗口标题。
- 不使用 Claude slug 作为标题。
- 不把 Codex Desktop 项目名与 thread title 混为同一字段。
- JSONL 单行损坏时跳过该行，继续处理后续新增内容。
- Codex global state 解析失败时保留已有项目显示名，等待下一次文件变化重试。
- metadata 不存在时使用持久化值或首条用户任务回退。

## 测试

新增测试覆盖：

1. Claude transcript 最后一条 `custom-title` 覆盖之前标题。
2. Claude 没有正式标题时使用首条 UserPromptSubmit 文本。
3. `firstUserPrompt` 不被后续用户消息覆盖。
4. Codex session index 同一 id 的后写 `thread_name` 覆盖旧值。
5. Codex CLI/Desktop 使用 sessionId 精确映射，不串线。
6. Codex Desktop project assignment 正确映射 `local-projects` 名称。
7. global state 解析失败时不清空已有项目名。
8. App 重启后能从 `sessions.json` 读取已持久化 metadata。
9. metadata 更新不改变 session phase、status、排序或活跃 subagent 数。
10. SessionSwitcher 没有 title 时不显示分隔符，长标题单行截断。

## 文档同步

实现完成后在项目 `CLAUDE.md` 的 Session/数据流说明中补充 `SessionMetadataMonitor` 的职责、标题数据源和回退规则。

## 成功标准

- Codex CLI/Desktop `thread_name` 改名后 1–2 秒内刷新。
- Claude Code `/rename` 后 1–2 秒内刷新。
- Codex Desktop 手动项目名后 1–2 秒内替换项目显示名。
- 没有正式标题时展示首条用户任务。
- SessionSwitcher 保持现有布局高度、快捷键与会话状态行为。
