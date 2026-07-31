# Waiting for Input 状态设计

## 背景

Claude Code 完成一轮回答时先发送 `Stop`，约 60 秒未收到用户回复后再发送 `Notification(notification_type: "idle_prompt")`。

当前实现将 `Stop` 映射为 `.idle` 并显示 `Task completed`，而 `idle_prompt` 只产生系统通知，不更新 session 状态。因此系统通知消失后，悬浮窗仍显示灰色完成/空闲状态，无法表达“正在等待用户输入”。

## 目标

- `idle_prompt` 到达后，session 明确进入等待输入状态。
- 悬浮窗用限时卡片提示 `Waiting for your input`。
- 卡片消失后，Session Switcher 仍保留等待输入标识。
- 用户提交下一条消息后恢复 Running。
- 不分析助手回答文本，不猜测问句。

## 状态模型

在 `AgentSession.Phase` 增加 `.waitingInput`：

| 事件 | 目标状态 |
|---|---|
| `Stop` / `StopFailure` | `.idle` |
| 已跟踪 session 的 `Notification(idle_prompt)` | `.waitingInput` |
| `UserPromptSubmit` | `.running` |

未知 session 的 `idle_prompt` 被忽略，不凭单条等待通知创建缺少项目和会话上下文的幽灵 session。
| `SessionEnd` | `status = .ended`, `phase = .idle` |

`.waitingInput` 表示 Claude Code 已明确通知正在等待用户回复。它与普通 `.idle` 分开，避免把“刚启动/阶段结束”和“需要用户操作”混为同一状态。

## 事件处理

### `idle_prompt`

`SessionStore.recordEvent(_:)` 在收到已跟踪 session 的 `Notification` 且 `notificationType == "idle_prompt"` 时：

1. 将对应 session 的 phase 更新为 `.waitingInput`。
2. 保持 session active。
3. 保留现有 idle 过期时间，使长期无回复的 session 仍按当前 5 分钟规则结束。
4. 触发 `onPhasesChanged`，刷新 overlay 和 Session Switcher。

### 用户继续输入

`UserPromptSubmit` 保持现有行为：

1. phase 更新为 `.running`。
2. 清除 idle 过期时间。
3. 关闭当前等待提示卡片。

## 悬浮窗

复用 `SessionFinishedStore` 和现有卡片布局，为 Toast 增加类型：

- `.completed`
- `.waitingInput`

收到 `Stop` 时仍显示完成卡片。收到 `idle_prompt` 后，用等待卡片替换当前完成卡片：

- 标题：项目名
- 状态：`Waiting for your input`
- 图标：橙色对话气泡
- 时长：复用现有 `taskCompletedToastDuration`，默认 8 秒

等待卡片自动消失后，session 仍保持 `.waitingInput`。

## Session Switcher

新增 phase 映射：

| Phase | 颜色 | 标签 |
|---|---|---|
| `.running` | 绿色 | `Running` |
| `.waitingInput` | 橙色 | `Waiting for input` |
| `.idle` | 灰色 | `Idle` |
| `.compacting` | 紫色 | `Compacting` |

Mascot 动画继续把 `.waitingInput` 归入现有 Idle 动画。本次不新增动画资源或状态机输入。

## 本地化

新增中英文字符串：

- `toast.waiting_for_input`
  - English: `Waiting for your input`
  - 中文：`等待你的回复`
- `switcher.waiting_for_input`
  - English: `Waiting for input`
  - 中文：`等待输入`

## 测试

### SessionStore

- `Stop → idle_prompt`：phase 从 `.idle` 变为 `.waitingInput`。
- `.waitingInput → UserPromptSubmit`：phase 变为 `.running`，清除 idle 过期时间。
- `.waitingInput` 超过现有 retention：session 正常 ended。

### Toast

- `Stop` 显示 `.completed` 卡片。
- `idle_prompt` 替换为 `.waitingInput` 卡片。
- 等待卡片复用完成卡片时长。
- `UserPromptSubmit` 关闭等待卡片。

### Session Switcher

- `.waitingInput` 显示橙色圆点和 `Waiting for input`。

### 运行时验证

使用当前唯一安装实例，通过真实 `POST /hook` 驱动：

1. `Stop` → 显示完成提示。
2. `Notification(idle_prompt)` → 切换为等待提示和 waiting phase。
3. 等待卡自动消失后 → Session Switcher 仍显示 Waiting。
4. `UserPromptSubmit` → 恢复 Running。

验证后清理注入数据，并保持只有一个 PeachyPet 进程。

## 非目标

- 不根据 `lastAssistantMessage` 是否为问句推断等待状态。
- 不修改 macOS 系统通知的展示时长。
- 不新增 Mascot 动画资源。
- 不改变 Stop 的系统通知与完成卡片语义。
