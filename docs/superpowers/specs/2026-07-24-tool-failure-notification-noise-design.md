# Tool Failed 通知降噪设计

## 背景

PeachyPet 当前把每个 `PostToolUseFailure` 立即转成 `Tool Failed` 通知，同时写入应用内通知中心并发送 macOS 系统通知。单次工具失败通常只是 Claude Code 或 Codex 的中间尝试，后续可能自动重试或改用其他方案，并不代表任务失败或需要用户介入。

## 目标

关闭所有单次工具失败通知，避免通知栏被 `Bash failed` 等可自动恢复的事件刷屏。

## 行为设计

- `PostToolUseFailure` 继续由 `EventProcessor` 处理。
- 事件继续写入 `EventStore`，因此 Activity Feed 保留完整失败记录。
- 事件继续更新 `SessionStore`，确保 session 活跃状态不变。
- `PostToolUseFailure` 不再创建 `AppNotification`。
- 因此该事件不进入应用内通知中心，也不触发 macOS 系统通知。
- 权限请求、任务完成、Claude/Codex 消息等其他通知行为保持不变。
- 不增加设置开关或失败次数阈值。

## 实现边界

只修改 `EventProcessor` 的通知生成策略，不改 hook 注册、事件解析、Activity Feed、NotificationService 或系统通知权限。

## 测试

新增回归测试验证：

1. `PostToolUseFailure` 仍写入 EventStore。
2. `PostToolUseFailure` 不写入 NotificationStore。
3. `PostToolUseFailure` 不调用系统通知投递。
4. 其他现有通知类型不受影响。

## 成功标准

运行中的工具失败仍可在 Activity Feed 查看，但 macOS 通知栏和 PeachyPet 通知中心不再出现 `Tool Failed` 通知。
