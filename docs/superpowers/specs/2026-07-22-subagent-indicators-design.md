# Subagent 状态短横线设计

**日期：** 2026-07-22  
**项目：** PeachyPet

## 目标

在会话切换器的每个 session 行中，以橙色短横线实时表示该 session 当前运行中的 subagent 数量，让用户无需新增文本或独立 session 卡片即可理解并发子任务状态。

## 范围

- 恢复 Claude Code 和 Codex 的 `SubagentStart` hook，与现有 `SubagentStop` 配对。
- 按 `agentId` 精确追踪每个 session 的活跃 subagent。
- 在 `SessionSwitcherRow` 中最多显示 5 条橙色短横线。
- session 进入 idle 或 ended 时清空全部 subagent 状态。

不包含：

- 不把 subagent 建成独立 session。
- 不展示 subagent 名称、类型或耗时。
- 不通过 subagent 状态推断 Codex Desktop 跨 session 的整体任务是否完成。
- 不在本改动中调整 `Task Completed` 通知语义。

## 数据模型

`SessionStore` 继续维护内存态映射：

```swift
[String: Set<String>]
```

键为 `sessionId`，集合元素为 `agentId`。`AgentSession.activeSubagentCount` 保存集合当前数量，供 SwiftUI 观察和渲染。

事件规则：

- `SubagentStart(agentId)`：把 `agentId` 插入该 session 的集合；重复事件不重复计数。
- `SubagentStop(agentId)`：从集合移除对应 `agentId`；未知或重复 Stop 不产生负数。
- 缺少 `agentId` 时：沿用整数增减降级策略，并保证最小值为 0。

`activeSubagentIds` 不持久化。应用重启后无法还原已在运行的 subagent，因此从 0 开始，后续事件重新建立状态；session 最终 idle/end 时仍会清零。

## 生命周期与清理

```text
SubagentStart(A) → active={A}   → 显示 1 条
SubagentStart(B) → active={A,B} → 显示 2 条
SubagentStop(A)  → active={B}   → 显示 1 条
session idle/end → active={}    → 不显示短线
```

以下状态转换必须同时清空 `activeSubagentIds[sessionId]` 和 `activeSubagentCount`：

- `Stop`
- `StopFailure`
- `SessionEnd`
- idle 超时结束 session
- 启动迁移将旧 session 结束
- internal turn 回滚删除临时 session

强制清零是防止 hook 漏发、进程异常退出或事件乱序留下残余短横线的最终保障。

## Hook 注册

`HookInstaller.hookEvents` 和 `CodexHookInstaller.hookEvents` 均恢复 `SubagentStart`。

安装逻辑已有按事件补齐 hook 的能力。新版应用执行安装/更新流程后，应把缺失的 `SubagentStart` 注册进现有配置，同时保留其他应用拥有的 hook。

现有注释中“SubagentStop 自身可以调整计数”的判断不成立：只收到 Stop 无法知道此前正在运行的数量，也无法展示开始过程，必须删除或更正。

## 视觉设计

位置位于 `SessionSwitcherRow` 的项目名称和状态文字下方，和文本左边缘对齐。

每条短横线：

- 宽度：10 pt
- 高度：2.5 pt
- 圆角：1.25 pt
- 间距：4 pt
- 颜色：`Constants.orangePrimary`
- 最大显示数量：5

渲染数量：

```swift
min(session.activeSubagentCount, 5)
```

数量为 0 时不渲染容器、不增加普通 session 行的高度。出现、消失和数量变化使用约 0.15 秒的 opacity 与 scale 动画；不使用循环动画，避免在多个并发 session 下产生视觉噪音。

超过 5 个 subagent 时仍显示 5 条，不增加 `+N` 文本；该元素表达“存在多个并发子任务”，不承担精确监控面板职责。

## 状态语义

- 左侧绿色/灰色/紫色圆点：整个 session 的主状态。
- 橙色短横线：该 session 内当前活跃的 subagent。
- 选中行左侧橙色竖线：键盘选择状态。

三者在位置、形状和职责上分离，避免把选中态、主运行态和子任务态混淆。

## 边界与异常

1. `SubagentStop` 不触发 `Task Completed` 通知。
2. session 收到 `Stop` 时，无论是否漏掉 `SubagentStop`，短横线都立即清空。
3. 重复 `SubagentStart` 不增加重复短线。
4. 未知 `SubagentStop` 不影响其他 subagent。
5. Codex Desktop 若使用多个 sessionId 表达父子工作，不会自动映射成这些短横线；只响应明确的 Subagent hook。
6. 切换器关闭时状态仍在 Store 中更新；再次打开时展示当前数量。

## 测试与验收

### SessionStore 单元测试

- 一个 Start 后计数为 1。
- 两个不同 agentId Start 后计数为 2。
- 重复 agentId Start 后仍为 1。
- Stop 精确移除对应 agentId。
- 重复或未知 Stop 不产生负数。
- Stop、StopFailure、SessionEnd 后计数归零。
- idle 超时和启动迁移结束 session 后计数归零。

### HookInstaller 单元测试

- Claude Code 安装结果包含 `SubagentStart` 和 `SubagentStop`。
- Codex 安装结果包含 `SubagentStart` 和 `SubagentStop`。
- 更新已有配置时补齐 `SubagentStart`，不删除第三方 hook。

### UI 验收

- 1、2、5、6 个活跃 subagent 分别显示 1、2、5、5 条。
- 0 个时普通行高度和当前版本一致。
- 切换器打开期间 Start/Stop 能实时改变短横线数量。
- session idle 后所有残留短横线立即消失。
- 选中背景、快捷键 badge、应用图标和文本布局不被遮挡。
