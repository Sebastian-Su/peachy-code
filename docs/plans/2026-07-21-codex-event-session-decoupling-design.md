# Codex 事件记录与 Session 状态解耦设计

## 背景与问题

PeachyPet 当前把 Codex JSONL 中映射出的每个 `AgentEvent` 同时送入三个下游：Activity Feed、SessionStore 和通知系统。这个默认耦合造成两个可见问题：

1. Codex 自动审批器和其他内部子流程也使用 `task_started` / `task_complete`。其结果常是 `{"outcome":"allow"}`、`{"exclude":[]}`、`{"suggestions":[]}` 等机器可读 JSON，却被显示为“Task Completed”系统通知。
2. `SessionStore.recordEvent(_:)` 在首次看到任何事件时都会创建 active Session。Stop、TaskCompleted、Notification、ConfigChange 等非活动事件，以及 Codex 启动时回放的旧日志，都可能把一次内部 turn 或已经完成的 turn 重新放进 Session 列表。Stop 又只把 phase 改为 idle，不结束 Session，最终列表持续增长。

前一轮窄修复只丢弃了自动审批 `task_complete`。它能消除一类通知，却没有处理对应的 `task_started`，可能让 Session 永久停在 Running；也没有覆盖其他内部 JSON 结果。因此需要从事件语义和下游职责上拆开，而不是继续按字符串打补丁。

## 目标与非目标

### 目标

- 所有可解析的 Codex 事件仍可进入 Activity Feed，保留排查证据。
- 只有真实工作活动才能创建、激活或更新 Session。
- 内部 turn 完成时恢复外层 Session 的原状态，不产生系统通知。
- 真实任务完成只产生一次完成通知，并让 Session 保留 Idle 5 分钟后自动结束。
- 5 分钟内的新活动可重新激活 Idle Session，并取消过期。
- 启动时安全迁移旧的 active + idle Session，避免升级后继续堆积。
- 未识别或损坏的 JSON 保守地按真实业务输出处理，避免吞掉用户结果。

### 非目标

- 不修改 Codex 的审批路由或 `~/.codex/hooks.json` 注册策略。
- 不清理或改写历史 Activity Feed 和通知存档。
- 不根据所有大括号文本做通用过滤。
- 不改变 Claude Code、Copilot 等适配器的既有完成语义。
- 不在本次改动中重做 Session 列表 UI 或持久化格式。

## 核心模型

### 1. 事件类型表达语义

在 `HookEventType` 增加 `InternalResult`。Codex mapper 对已知内部结果仍生成事件，但不再把它伪装成 Stop 或 TaskCompleted。这样 Activity Feed 能记录内部事件，下游也能显式区分其行为。

内部结果只识别结构确定的 schema：

- 审批结果：键集合仅属于 `outcome`、`risk_level`、`user_authorization`、`rationale`，且 `outcome` 为 `allow` 或 `deny`。
- 排除结果：对象仅包含 `exclude`，其值为数组。
- 建议结果：对象仅包含 `suggestions`，其值为数组。

额外业务键会使对象回落为普通任务结果。例如 `{"outcome":"allow","operation":"feature-rollout"}` 仍是用户可见完成。无法解析的 JSON 也保持普通完成语义。

`item_completed` 映射出的步骤、reasoning、token 等 `TaskCompleted` 只作为 Activity Feed 记录，不再直接产生系统通知或 Session 状态变化。真正的 turn 完成仍由 `task_complete` 生成 Stop。

### 2. 下游处置分类

`EventProcessor` 对事件计算处置，而不是无条件调用所有下游：

| 处置 | Activity Feed | SessionStore | 系统/应用通知 |
|---|---:|---:|---:|
| `recordOnly` | 是 | 否，或仅执行内部 turn 回滚 | 否 |
| `sessionActivity` | 是 | 是 | 按现有规则，仅限需要通知的活动 |
| `userVisibleCompletion` | 是 | 是，进入 Idle 保留期 | 仅 Stop 一次 |

`InternalResult` 和 `TaskCompleted` 属于 `recordOnly`。Stop 属于 `userVisibleCompletion`。SessionStart、UserPromptSubmit、工具生命周期、权限请求、compact 和 subagent 生命周期属于 `sessionActivity`。普通 Notification、ConfigChange 等不会仅因首次出现就创建 Session。

这里的关键约束是：`eventStore.append(_:)` 永远执行；创建 Session、推进状态和显示通知分别由事件语义决定。

## Session 状态机

### 真实 turn

1. UserPromptSubmit 或其他真实工作事件将 Session 置为 active + running，并清空 `idleUntil`。
2. Stop 将 Session 置为 active + idle，设置 `idleUntil = now + 5 minutes`。
3. 5 分钟内出现真实工作事件时，Session 回到 running，`idleUntil` 清空。
4. 到达 `idleUntil` 且没有新活动时，Session 置为 ended + idle，并从 active Session 列表消失。
5. SessionEnd 立即结束，不等待保留期。

### 内部 turn 回滚

Codex 的自动审批等内部 turn 在开始时无法仅靠 `task_started` 判断其性质。因此 mapper 仍把 `task_started` 表达为 UserPromptSubmit，SessionStore 按 `taskId` 保存 turn 开始前的快照：Session 是否存在、status、phase 和 `idleUntil`。

当相同 `taskId` 的 `InternalResult` 到达时：

- 若此前已有外层 Session，恢复快照。例如外层正在 Running，审批 turn 完成后仍是 Running；外层原为 Idle，则恢复 Idle 及原过期时间。
- 若 Session 仅由该内部 turn 创建，删除该临时 Session。
- 若缺少 `taskId` 或找不到快照，只记录事件，不修改 Session，避免错误回滚其他 turn。
- 当相同 `taskId` 收到真实 Stop 时，丢弃快照并按真实完成进入 Idle 保留期。

快照只保存在内存，不持久化。应用重启后缺失快照时采用“内部结果不改 Session”的保守策略；随后由正常活动、Idle 过期和 SessionEnd 收敛状态。

## 持久化、计时与迁移

`AgentSession` 新增可选 `idleUntil: Date?`，并加入 Codable。旧 JSON 没有该字段时可继续解码。

SessionStore 接收可注入的 `now` 闭包和 Idle 保留时长，生产环境默认 `Date.init` 与 300 秒，测试使用固定时钟。Store 维护单个 Idle 过期 Timer，每次 Session 状态改变后重新安排到最近的 `idleUntil`，而不是为每个 Session 创建独立 Timer。Timer 触发后执行一次同步过期扫描、持久化变化并安排下一次到期。

启动迁移规则：

- active + idle 且已有 `idleUntil`：若已过期立即结束，否则保留并安排 Timer。
- active + idle 且没有 `idleUntil`：使用 `lastEventAt ?? startedAt` 加 5 分钟补出截止时间；已过期立即结束。
- running / compacting Session 不补 `idleUntil`。
- SessionEnd 或崩溃 reconciliation 结束 Session 时清空 `idleUntil`。

这样历史 Idle Session 会在升级启动时立即收敛，而不会再依赖“系统是否存在任意 Codex/Claude 进程”的一小时兜底逻辑。

## 通知规则

完成通知只由真实 Stop 生成。对应的 TaskCompleted 是 Activity Feed 元数据，不再生成第二条通知。InternalResult 永不进入 NotificationStore，也不调用系统通知服务。

其他既有高价值通知保持不变：权限请求、需要用户输入、工具失败、Session 生命周期和 compact 通知仍按现有规则处理。本次只消除“内部结果”和“同一 turn 的重复完成通知”。

## 测试策略

### Mapper 测试

- 三种审批 schema 映射为 `InternalResult`，保留 `taskId` 和原始结果文本。
- `exclude`、`suggestions` schema 映射为 `InternalResult`。
- 带额外业务键的 outcome JSON 仍映射为真实 Stop + TaskCompleted。
- 未知 JSON、损坏 JSON 和普通文本仍映射为真实完成。
- item_completed 仍可进入 Activity Feed，但不被视为 turn 完成。

### SessionStore 测试

- record-only 事件不会创建 Session。
- 纯内部 turn：task_started 创建的临时 Session 在 InternalResult 后被删除。
- 嵌套内部 turn：外层 Running 在内部结果后恢复 Running。
- 内部 turn 从 Idle 开始时恢复原 `idleUntil`。
- 真实 Stop 进入 Idle 5 分钟；期间活动可恢复 Running；到期后结束。
- 缺少 taskId 的 InternalResult 不改变 Session。
- 旧 active + idle Session 启动迁移后按 `lastEventAt + 5 minutes` 结束或安排过期。

### EventProcessor 测试

- InternalResult 只写 EventStore，不创建 Session、不写 NotificationStore。
- TaskCompleted 只写 EventStore，不产生完成通知。
- Stop 只产生一条完成通知并推进 Session 到 Idle。
- 既有权限、问题和工具失败通知不回归。

最终运行 `swift test` 和 `swift build`。验收标准是：所有测试通过；模拟一组内部审批事件后 Activity Feed 有记录、Session 数量不增加、系统无 Task Completed 通知；真实任务完成仍有且仅有一次通知，并在 5 分钟后从 active Session 列表消失。

## 风险与控制

- **误判业务 JSON：** 采用白名单 schema 且限制键集合；未知结构回落为真实完成。
- **内部 turn 没有配对结果：** 快照只影响当前内存状态，不主动结束 Session；后续真实事件会覆盖，崩溃恢复仍作为安全网。
- **回放旧日志重建 Session：** record-only 不创建 Session，真实 Stop 对不存在 Session 不应创建；历史 Idle 由启动迁移立即收敛。
- **Timer 测试不稳定：** 核心过期逻辑做成同步可调用方法，测试注入时间并直接触发扫描，不等待真实 5 分钟。
- **跨适配器回归：** 新 `InternalResult` 仅由 Codex mapper 产生；其他适配器的事件映射保持不变。

## 验收结论

本设计将“日志事实”“Session 活跃状态”“用户提醒”拆成三个独立决策。内部事件继续可观测，但不再冒充用户任务、不再制造活跃 Session；真实完成保留短暂可操作窗口后自动退出列表，解决通知噪声和 Session 列表膨胀的共同根因。
