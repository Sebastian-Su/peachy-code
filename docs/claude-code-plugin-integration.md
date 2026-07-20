# PeachyPet — Claude Code Plugin 集成文档

> 本文档详细说明 PeachyPet 如何通过 Claude Code Hooks 机制接入 Claude Code，包括支持的能力、接入方式、可接收的数据及其完整格式。

---

## 目录

1. [架构概览](#1-架构概览)
2. [接入方式](#2-接入方式)
3. [支持的能力矩阵](#3-支持的能力矩阵)
4. [Hook 事件类型详解](#4-hook-事件类型详解)
5. [数据流与处理管线](#5-数据流与处理管线)
6. [权限请求的交互协议](#6-权限请求的交互协议)
7. [会话状态追踪](#7-会话状态追踪)
8. [接入开发指南](#8-接入开发指南)
9. [附录 A：Claude Code 全量 Hook 事件格式](#附录-aclaude-code-全量-hook-事件格式)
10. [附录 B：完整 JSON 字段参考](#附录-b完整-json-字段参考)

---

## 1. 架构概览

PeachyPet 采用**双层集成架构**与 Claude Code 通信：

```
Claude Code Runtime
    │
    │  触发 Hook (stdin JSON)
    ▼
~/.peachypet/hooks/hook-sender.sh       ← 注册到 ~/.claude/settings.json
    │
    │  HTTP POST (JSON body)
    ▼
PeachyPet LocalServer (localhost:45832)
    │
    │  解码 → AgentEvent
    ▼
EventBus → 分发到各 Store / UI
```

**核心组件：**

| 组件 | 文件 | 职责 |
|------|------|------|
| HookInstaller | `Sources/Services/HookInstaller.swift` | 在 `~/.claude/settings.json` 注册/注销 hooks，生成 hook 转发脚本 |
| LocalServer | `Sources/Services/LocalServer.swift` | 本地 HTTP 服务，接收 hook 事件 |
| ClaudeCodeAdapter | `Sources/Adapters/ClaudeCode/ClaudeCodeAdapter.swift` | 封装 LocalServer + HookInstaller 的适配器 |
| HookConnectionTransport | `Sources/Adapters/ClaudeCode/HookConnectionTransport.swift` | 保持 TCP 连接以响应权限请求 |
| AgentEvent | `Sources/Models/AgentEvent.swift` | 事件数据模型 |
| EventProcessor | `Sources/Services/EventProcessor.swift` | 事件路由与处理 |

---

## 2. 接入方式

### 2.1 Hook 注册

PeachyPet 通过修改 `~/.claude/settings.json` 的 `hooks` 字段注册事件监听。每个事件类型注册一个 entry，指向统一的 hook 脚本：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.peachypet/hooks/hook-sender.sh"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.peachypet/hooks/hook-sender.sh"
          }
        ]
      }
    ]
  }
}
```

- `matcher: ""` 表示匹配所有（不过滤特定工具名或来源）
- 所有 19 个事件类型共用同一个 hook 脚本

### 2.2 Hook 脚本（hook-sender.sh）

脚本位于 `~/.peachypet/hooks/hook-sender.sh`，由 `HookInstaller.ensureScriptExists()` 自动生成和更新。

**工作流程：**

1. **健康检查**：先 `curl GET /health`，如果服务不可达立即退出（避免卡住 Claude Code）
2. **读取 stdin**：`cat` 读取 Claude Code 传入的 JSON
3. **提取事件名**：`grep` 提取 `hook_event_name`
4. **注入进程信息**：遍历进程树，找到终端应用 PID 和 Shell PID，注入到 JSON
5. **分发请求**：
   - **PermissionRequest**：阻塞式 `curl POST /hook`，等待用户决策（最长 120 秒），根据 HTTP 状态码返回退出码
   - **其他事件**：非阻塞 `curl POST /hook`（2 秒超时），fire-and-forget

**退出码协议：**

| HTTP 状态码 | 退出码 | 含义 |
|-------------|--------|------|
| 200 | 0 | 允许（Allow） |
| 403 | 2 | 拒绝（Deny） |

### 2.3 HTTP 服务端点

| 端点 | 方法 | 用途 | 是否阻塞 |
|------|------|------|----------|
| `/health` | GET | Hook 脚本存活检测 | 否 |
| `/hook` | POST | 接收 Claude Code 所有事件 | 仅 PermissionRequest |
| `/input` | POST | 自定义状态机输入 | 否 |
| `/install` | POST/OPTIONS | 从 Web 导入 Mascot 配置（CORS） | 否 |

**默认端口**：`45832`，失败时自动尝试 `45832-45841` 范围。

---

## 3. 支持的能力矩阵

### 3.1 订阅的事件类型（共 19 种）

| 事件名 | 中文说明 | 阻塞性 | 用途 |
|--------|----------|--------|------|
| `SessionStart` | 会话开始 | 否 | 创建/恢复会话追踪 |
| `SessionEnd` | 会话结束 | 否 | 标记会话结束 |
| `UserPromptSubmit` | 用户提交提示 | 否* | 标记会话进入运行态 |
| `PreToolUse` | 工具调用前 | 否* | 记录工具调用、关联 tool_use_id |
| `PostToolUse` | 工具调用成功后 | 否 | 更新工具状态 |
| `PostToolUseFailure` | 工具调用失败 | 否 | 记录失败、触发通知 |
| `PermissionRequest` | 权限请求 | **是** | 显示权限气泡，等待用户决策 |
| `Stop` | Agent 停止 | 否 | 标记会话进入空闲态 |
| `StopFailure` | Agent 错误停止 | 否 | 记录错误 |
| `SubagentStart` | 子代理启动 | 否 | 追踪活跃子代理数 |
| `SubagentStop` | 子代理停止 | 否 | 追踪活跃子代理数 |
| `Notification` | 通知 | 否 | 显示通知 |
| `PreCompact` | 上下文压缩前 | 否 | 标记会话进入压缩态 |
| `PostCompact` | 上下文压缩后 | 否 | 恢复会话运行态 |
| `TaskCompleted` | 任务完成 | 否 | 记录任务完成 |
| `TeammateIdle` | 队友空闲 | 否 | 协作通知 |
| `ConfigChange` | 配置变更 | 否 | 记录配置变更 |
| `WorktreeCreate` | 工作树创建 | 否 | 记录 Git 工作树操作 |
| `WorktreeRemove` | 工作树移除 | 否 | 记录 Git 工作树操作 |

> *注：PeachyPet 对 `UserPromptSubmit` 和 `PreToolUse` 不做阻塞处理（脚本以 fire-and-forget 方式发送），仅用于状态追踪。

### 3.2 能力总结

| 能力 | 支持 | 说明 |
|------|------|------|
| 会话生命周期追踪 | ✅ | SessionStart/End，含崩溃恢复 |
| 工具调用监控 | ✅ | Pre/Post/Failure 全链路 |
| 权限请求拦截与响应 | ✅ | 阻塞式，支持 Allow/Deny/修改输入/权限建议 |
| AskUserQuestion 响应 | ✅ | 解析结构化问题，支持选项选择和文本输入 |
| 通知展示 | ✅ | 桌面通知气泡 |
| 子代理追踪 | ✅ | 记录子代理启动/停止 |
| 上下文压缩追踪 | ✅ | 标记压缩阶段 |
| 任务完成通知 | ✅ | TaskCompleted 事件 |
| 进程关联 | ✅ | 注入 terminal_pid / shell_pid |
| 工作树操作追踪 | ✅ | Create/Remove |
| ExitPlanMode 计划预览 | ✅ | 读取计划文件内容显示在权限气泡中 |

---

## 4. Hook 事件类型详解

### 4.1 会话事件

#### SessionStart

Claude Code 新会话启动时触发。

```json
{
  "hook_event_name": "SessionStart",
  "session_id": "abc123-def456",
  "cwd": "/Users/dev/my-project",
  "source": "startup",
  "model": "claude-sonnet-4-6",
  "transcript_path": "/Users/dev/.claude/projects/.../transcript.jsonl",
  "permission_mode": "default"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `source` | string | 启动来源：`startup`（新会话）、`resume`（恢复）、`clear`（清除后）、`compact`（压缩后） |
| `model` | string | 使用的模型 ID |

#### SessionEnd

会话结束时触发。

```json
{
  "hook_event_name": "SessionEnd",
  "session_id": "abc123-def456",
  "cwd": "/Users/dev/my-project",
  "reason": "user_exit"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `reason` | string | 结束原因 |

### 4.2 工具事件

#### PreToolUse

工具执行前触发，包含工具名和输入参数。

```json
{
  "hook_event_name": "PreToolUse",
  "session_id": "abc123",
  "tool_name": "Bash",
  "tool_input": {
    "command": "npm test"
  },
  "tool_use_id": "toolu_abc123",
  "cwd": "/Users/dev/my-project",
  "transcript_path": "/path/to/transcript.jsonl"
}
```

#### PostToolUse

工具成功执行后触发，包含工具输出。

```json
{
  "hook_event_name": "PostToolUse",
  "session_id": "abc123",
  "tool_name": "Bash",
  "tool_input": {
    "command": "npm test"
  },
  "tool_response": {
    "stdout": "PASS 42 tests",
    "exitCode": 0
  },
  "tool_use_id": "toolu_abc123"
}
```

#### PostToolUseFailure

工具执行失败时触发。

```json
{
  "hook_event_name": "PostToolUseFailure",
  "session_id": "abc123",
  "tool_name": "Bash",
  "tool_input": {
    "command": "invalid-command"
  },
  "tool_response": {
    "stderr": "command not found",
    "exitCode": 127
  }
}
```

### 4.3 权限事件

#### PermissionRequest

Claude Code 需要用户授权时触发。**这是唯一的阻塞式事件**，hook 脚本会保持 TCP 连接等待响应。

```json
{
  "hook_event_name": "PermissionRequest",
  "session_id": "abc123",
  "tool_name": "Bash",
  "tool_input": {
    "command": "rm -rf ./dist"
  },
  "cwd": "/Users/dev/my-project",
  "permission_mode": "default",
  "permission_suggestions": [
    {
      "type": "addRules",
      "destination": "localSettings",
      "behavior": "allow",
      "rules": [
        {
          "toolName": "Bash",
          "ruleContent": "/Users/dev/my-project/**"
        }
      ]
    },
    {
      "type": "setMode",
      "mode": "acceptEdits"
    }
  ]
}
```

**PermissionRequest 也用于 AskUserQuestion 工具**：

```json
{
  "hook_event_name": "PermissionRequest",
  "session_id": "abc123",
  "tool_name": "AskUserQuestion",
  "tool_input": {
    "questions": [
      {
        "question": "Which database should we use?",
        "header": "Database",
        "options": [
          { "label": "PostgreSQL", "description": "Relational, ACID compliant" },
          { "label": "MongoDB", "description": "Document-oriented, flexible schema" }
        ],
        "multiSelect": false
      }
    ]
  }
}
```

### 4.4 停止事件

#### Stop

Claude Code 完成当前轮次时触发。

```json
{
  "hook_event_name": "Stop",
  "session_id": "abc123",
  "reason": "finished",
  "stop_hook_active": true,
  "last_assistant_message": "I've completed the refactoring. The tests pass.",
  "cwd": "/Users/dev/my-project"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `reason` | string | 停止原因：`finished`、`interrupted` 等 |
| `stop_hook_active` | bool | Stop hook 是否被触发 |
| `last_assistant_message` | string | 最后一条助手消息 |

#### StopFailure

因 API 错误导致停止。

```json
{
  "hook_event_name": "StopFailure",
  "session_id": "abc123",
  "reason": "rate_limit"
}
```

### 4.5 子代理事件

#### SubagentStart

```json
{
  "hook_event_name": "SubagentStart",
  "session_id": "abc123",
  "agent_id": "subagent-xyz",
  "agent_type": "Explore"
}
```

#### SubagentStop

```json
{
  "hook_event_name": "SubagentStop",
  "session_id": "abc123",
  "agent_id": "subagent-xyz",
  "agent_type": "Explore"
}
```

### 4.6 通知事件

#### Notification

```json
{
  "hook_event_name": "Notification",
  "session_id": "abc123",
  "message": "Claude is waiting for your input",
  "title": "Attention needed",
  "notification_type": "permission_prompt"
}
```

| `notification_type` 值 | 说明 |
|------------------------|------|
| `permission_prompt` | 权限请求提醒 |
| `idle_prompt` | 空闲等待提醒 |
| `auth_success` | 认证成功 |
| `elicitation_dialog` | MCP 输入请求 |

### 4.7 上下文压缩事件

#### PreCompact / PostCompact

```json
{
  "hook_event_name": "PreCompact",
  "session_id": "abc123"
}
```

```json
{
  "hook_event_name": "PostCompact",
  "session_id": "abc123"
}
```

### 4.8 任务事件

#### TaskCompleted

```json
{
  "hook_event_name": "TaskCompleted",
  "session_id": "abc123",
  "task_id": "task-001",
  "task_subject": "Fix authentication bug in login flow"
}
```

### 4.9 用户提交事件

#### UserPromptSubmit

```json
{
  "hook_event_name": "UserPromptSubmit",
  "session_id": "abc123",
  "cwd": "/Users/dev/my-project"
}
```

### 4.10 协作事件

#### TeammateIdle

```json
{
  "hook_event_name": "TeammateIdle",
  "session_id": "abc123"
}
```

### 4.11 配置变更事件

#### ConfigChange

```json
{
  "hook_event_name": "ConfigChange",
  "session_id": "abc123"
}
```

### 4.12 工作树事件

#### WorktreeCreate / WorktreeRemove

```json
{
  "hook_event_name": "WorktreeCreate",
  "session_id": "abc123"
}
```

---

## 5. 数据流与处理管线

```
Claude Code Hook 触发
    ↓  (stdin JSON)
hook-sender.sh
    ↓  注入 terminal_pid / shell_pid
    ↓  POST /hook (JSON body)
LocalServer.processRequest()
    ↓  JSONDecoder → AgentEvent
    ↓
    ├─→ [PermissionRequest?]
    │     ├─→ onPermissionRequest(event, connection)
    │     │     └─→ PendingPermissionStore.add()
    │     │           └─→ UI 显示权限气泡
    │     │           └─→ 用户决策 → HookConnectionTransport.sendDecision()
    │     │                 └─→ HTTP Response → hook-sender.sh → Claude Code
    │     └─→ onEventReceived(event)  ← 同时记录事件
    │
    └─→ [其他事件]
          └─→ onEventReceived(event)
                └─→ EventBus 分发
                      ├─→ EventProcessor → EventStore / SessionStore / NotificationStore
                      ├─→ OverlayManager → UI 动画更新
                      └─→ AppStore 回调
```

---

## 6. 权限请求的交互协议

### 6.1 请求阶段

1. Claude Code 触发 `PermissionRequest` hook
2. hook-sender.sh 以阻塞方式 `POST /hook`，保持 TCP 连接
3. LocalServer 识别 PermissionRequest，不关闭连接，转给 `onPermissionRequest`
4. `PendingPermissionStore` 创建 `PendingPermission`，关联前序 `PreToolUse` 的 `tool_use_id`
5. UI 显示权限气泡

### 6.2 响应格式

#### 简单 Allow/Deny

```
HTTP/1.1 200 OK                    ← Allow
Content-Type: application/json
Connection: close
X-Exit-Code: 0

(空 body 或 "OK")
```

```
HTTP/1.1 403 Forbidden             ← Deny
Content-Type: application/json
Connection: close
X-Exit-Code: 2

(空 body)
```

#### 带修改输入的 Allow

```json
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: ...
Connection: close

{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow",
      "updatedInput": {
        "command": "rm -rf ./dist --dry-run"
      }
    }
  }
}
```

#### 带权限建议的 Allow

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow",
      "updatedPermissions": [
        {
          "type": "addRules",
          "destination": "localSettings",
          "behavior": "allow",
          "rules": [
            { "toolName": "Bash", "ruleContent": "/Users/dev/project/**" }
          ]
        }
      ]
    }
  }
}
```

### 6.3 超时与取消

- hook-sender.sh 无 `--max-time` 参数（由 Claude Code 侧管理超时）
- 如果用户在终端直接回答，Claude Code 会 SIGTERM 杀死 hook-sender.sh
- hook-sender.sh 捕获 SIGTERM/SIGHUP，杀死 curl 子进程并清理临时文件
- HookConnectionTransport 监控 TCP 连接关闭事件，自动清理 UI

### 6.4 AskUserQuestion 响应

当 `tool_name` 为 `AskUserQuestion` 时，用户选择选项后通过 `updatedInput` 返回答案：

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow",
      "updatedInput": {
        "questions": [...],
        "answers": {
          "Which database should we use?": "PostgreSQL"
        }
      }
    }
  }
}
```

---

## 7. 会话状态追踪

### 7.1 会话模型

```swift
struct AgentSession {
    let id: String              // session_id
    let projectDir: String?     // cwd
    let projectName: String?    // 从 cwd 提取
    var agentSource: AgentSource // .claudeCode / .copilot / .codex
    var status: Status          // .active / .ended
    var phase: Phase            // .idle / .running / .compacting
    var eventCount: Int
    var startedAt: Date
    var lastEventAt: Date?
    var lastToolName: String?
    var activeSubagentCount: Int
    var terminalPid: Int?
    var terminalBundleId: String?
    var shellPid: Int?
    var transcriptPath: String?
}
```

### 7.2 Phase 状态机

```
                UserPromptSubmit / PreToolUse / PermissionRequest
    ┌─────────────────────────────────────────────────────────────┐
    │                                                             ▼
  idle ◄──────────────── Stop ─────────────────────────── running
    ▲                                                     │     ▲
    │                                                     │     │
    └──── PostCompact ──── compacting ◄── PreCompact ─────┘     │
                                                                │
                            PostCompact ────────────────────────┘
```

### 7.3 崩溃恢复

SessionStore 每 2 分钟执行一次 reconciliation：
- 检查 assistant 进程是否仍然活跃
- 读取 transcript JSONL 尾部检测 `[Request interrupted by user]`
- 超过 1 小时无事件且 transcript 未修改的会话自动结束

---

## 8. 接入开发指南

### 8.1 作为 Plugin 接入的最小步骤

1. **注册 hooks**：在 `~/.claude/settings.json` 的 `hooks` 字段中为目标事件添加条目
2. **实现 hook handler**：创建 shell 脚本或 HTTP 服务接收事件
3. **处理 stdin JSON**：解析 Claude Code 传入的 JSON 数据
4. **（可选）响应阻塞事件**：对 PermissionRequest 等阻塞事件返回决策 JSON

### 8.2 最简 Hook 脚本示例

```bash
#!/bin/bash
# 读取 Claude Code 传入的 JSON
INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name')

# 记录到日志
echo "$(date): $EVENT" >> ~/.my-plugin/events.log

# 对于 PermissionRequest，返回 allow
if [ "$EVENT" = "PermissionRequest" ]; then
  echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
  exit 0
fi

exit 0
```

### 8.3 settings.json 注册格式

```json
{
  "hooks": {
    "<EventName>": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/your/hook.sh"
          }
        ]
      }
    ]
  }
}
```

### 8.4 HTTP 方式接入

也可以使用 `type: "http"` 直接以 HTTP POST 方式接收事件：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "http",
            "url": "http://localhost:8080/hooks/pre-tool-use",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

---

## 附录 A：Claude Code 全量 Hook 事件格式

> 以下列出 Claude Code **所有已知 Hook 事件类型**及其完整输入/输出格式。PeachyPet 当前订阅其中 19 种（标记为 ✅），其余为 Claude Code 支持但 PeachyPet 未订阅的事件。

### A.1 通用输入字段（所有事件共享）

```json
{
  "session_id": "string — 会话 ID",
  "transcript_path": "string — transcript JSONL 文件路径",
  "cwd": "string — 当前工作目录",
  "hook_event_name": "string — 事件名称",
  "permission_mode": "string — 权限模式（default/plan/acceptEdits 等）",
  "effort": { "level": "string — 当前 effort 级别（low/medium/high/max）" },
  "agent_id": "string? — 子代理 ID（仅子代理上下文中存在）",
  "agent_type": "string? — 子代理类型（Explore/general-purpose 等）"
}
```

### A.2 通用输出格式

```json
{
  "continue": "boolean — false 则终止 Claude",
  "stopReason": "string — continue:false 时的终止原因",
  "suppressOutput": "boolean — true 则不显示 hook 输出",
  "systemMessage": "string — 警告信息显示给用户",
  "terminalSequence": "string — 终端转义序列",
  "hookSpecificOutput": {
    "hookEventName": "string — 事件名",
    "additionalContext": "string — 注入给 Claude 的上下文",
    "...": "其他事件特定字段（见各事件详情）"
  }
}
```

### A.3 完整事件列表

---

#### SessionStart ✅

**触发时机**：新会话/恢复/清除/压缩后
**Matcher**：`startup` | `resume` | `clear` | `compact`
**阻塞**：否

**输入（额外字段）**：
```json
{
  "source": "startup | resume | clear | compact",
  "model": "claude-sonnet-4-6",
  "session_title": "string? — 已有标题"
}
```

**输出（hookSpecificOutput）**：
```json
{
  "hookEventName": "SessionStart",
  "additionalContext": "string — 注入上下文（如分支信息）",
  "sessionTitle": "string — 设置会话标题",
  "watchPaths": ["string — 监视的文件路径"],
  "reloadSkills": "boolean — 重新加载 skills",
  "initialUserMessage": "string — 首轮消息"
}
```

---

#### SessionEnd ✅

**触发时机**：会话结束
**Matcher**：`clear` | `logout` | `other`
**阻塞**：否

**输入（额外字段）**：
```json
{
  "reason": "string — 结束原因"
}
```

---

#### Setup

**触发时机**：`claude --init-only` 或 `claude -p --init|--maintenance`
**Matcher**：`init` | `maintenance`
**阻塞**：否

**输入（额外字段）**：
```json
{
  "trigger": "init | maintenance"
}
```

---

#### UserPromptSubmit ✅

**触发时机**：用户提交提示后、处理前
**Matcher**：不支持
**阻塞**：是（exit 2 阻止提交）
**超时默认**：30 秒

**输入（额外字段）**：
```json
{
  "prompt": "string — 用户输入的提示文本"
}
```

**输出**：
```json
{
  "decision": "block",
  "reason": "string — 阻止原因",
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "string — 注入上下文"
  }
}
```

---

#### PreToolUse ✅

**触发时机**：工具执行前
**Matcher**：工具名（如 `Bash`、`Edit`、`Write`、`mcp__*`）
**阻塞**：是
**支持 `if` 过滤**：是（如 `Bash(rm *)`）

**输入（额外字段）**：
```json
{
  "tool_name": "string — 工具名",
  "tool_input": { "...": "工具参数（结构取决于工具类型）" },
  "tool_use_id": "string — 工具调用 ID"
}
```

**常见 tool_input 结构**：

| 工具 | tool_input 示例 |
|------|----------------|
| Bash | `{"command": "npm test"}` |
| Edit | `{"file_path": "/a.ts", "old_string": "...", "new_string": "..."}` |
| Write | `{"file_path": "/a.ts", "content": "..."}` |
| Read | `{"file_path": "/a.ts", "limit": 100, "offset": 0}` |
| Glob | `{"pattern": "src/**/*.ts"}` |
| Grep | `{"pattern": "TODO", "path": "src/"}` |
| AskUserQuestion | `{"questions": [{"question":"...", "header":"...", "options":[...], "multiSelect":false}]}` |
| ExitPlanMode | `{"allowedPrompts": [...]}` |
| Agent | `{"description":"...", "prompt":"..."}` |
| WebFetch | `{"url":"...", "prompt":"..."}` |
| WebSearch | `{"query":"..."}` |

**输出（hookSpecificOutput）**：
```json
{
  "hookEventName": "PreToolUse",
  "permissionDecision": "allow | deny | ask | defer",
  "permissionDecisionReason": "string — 原因",
  "updatedInput": { "command": "modified command" },
  "additionalContext": "string — 上下文"
}
```

---

#### PostToolUse ✅

**触发时机**：工具成功执行后
**Matcher**：工具名
**阻塞**：否
**支持 `if` 过滤**：是

**输入（额外字段）**：
```json
{
  "tool_name": "string",
  "tool_input": { "...": "工具参数" },
  "tool_output": "any — 工具输出（字符串或对象）",
  "tool_use_id": "string"
}
```

**输出（hookSpecificOutput）**：
```json
{
  "hookEventName": "PostToolUse",
  "additionalContext": "string",
  "updatedToolOutput": "string — 修改后的输出",
  "decision": "block",
  "reason": "string — 阻止原因"
}
```

---

#### PostToolUseFailure ✅

**触发时机**：工具执行失败
**Matcher**：工具名
**阻塞**：否
**支持 `if` 过滤**：是

**输入**：与 PostToolUse 相同，`tool_response` 包含错误信息。

---

#### PostToolBatch

**触发时机**：一批并行工具调用全部完成后
**Matcher**：不支持
**阻塞**：是

**输出**：
```json
{
  "decision": "block",
  "reason": "string"
}
```

---

#### PermissionRequest ✅

**触发时机**：需要用户授权
**Matcher**：工具名
**阻塞**：是
**支持 `if` 过滤**：是

**输入（额外字段）**：
```json
{
  "tool_name": "string",
  "tool_input": { "...": "工具参数" },
  "permission_suggestions": [
    {
      "type": "addRules | setMode",
      "destination": "session | localSettings",
      "behavior": "allow",
      "rules": [{ "toolName": "string", "ruleContent": "string" }],
      "mode": "string"
    }
  ]
}
```

**输出（hookSpecificOutput）**：
```json
{
  "hookEventName": "PermissionRequest",
  "decision": {
    "behavior": "allow | deny",
    "updatedInput": { "...": "修改后的参数" },
    "updatedPermissions": [{ "...": "权限规则" }]
  }
}
```

---

#### PermissionDenied

**触发时机**：工具调用被 auto mode 分类器拒绝
**Matcher**：工具名
**阻塞**：否

**输出（hookSpecificOutput）**：
```json
{
  "hookEventName": "PermissionDenied",
  "retry": true
}
```

---

#### Stop ✅

**触发时机**：Claude 完成当前轮次
**Matcher**：不支持
**阻塞**：是（exit 2 可阻止停止，使对话继续）

**输入（额外字段）**：
```json
{
  "reason": "string — 停止原因",
  "stop_hook_active": "boolean",
  "last_assistant_message": "string — 最后一条助手消息"
}
```

**输出（hookSpecificOutput）**：
```json
{
  "hookEventName": "Stop",
  "decision": "block",
  "reason": "string — 阻止原因",
  "additionalContext": "string — 反馈给 Claude 继续对话"
}
```

---

#### StopFailure ✅

**触发时机**：因 API 错误停止
**Matcher**：`rate_limit` | `overloaded` | `authentication_failed` | `billing_error` | `server_error` | `unknown`
**阻塞**：否
**输出**：被忽略

**输入（额外字段）**：
```json
{
  "error_type": "string — 错误类型",
  "reason": "string"
}
```

---

#### Notification ✅

**触发时机**：Claude Code 发送通知
**Matcher**：`permission_prompt` | `idle_prompt` | `auth_success` | `elicitation_dialog` 等
**阻塞**：否

**输入（额外字段）**：
```json
{
  "message": "string — 通知内容",
  "title": "string? — 通知标题",
  "notification_type": "string — 通知类型"
}
```

---

#### SubagentStart ✅ / SubagentStop ✅

**触发时机**：子代理启动/停止
**Matcher**：代理类型（`general-purpose`、`Explore` 等）
**阻塞**：否（SubagentStart）、是（SubagentStop）

**输入（额外字段）**：
```json
{
  "agent_id": "string — 子代理 ID",
  "agent_type": "string — 子代理类型"
}
```

---

#### PreCompact ✅ / PostCompact ✅

**触发时机**：上下文压缩前/后
**阻塞**：否

（无额外字段，仅通用字段）

---

#### TaskCompleted ✅

**触发时机**：任务完成
**阻塞**：否

**输入（额外字段）**：
```json
{
  "task_id": "string — 任务 ID",
  "task_subject": "string — 任务描述"
}
```

---

#### TeammateIdle ✅

**触发时机**：协作队友空闲
**阻塞**：否

---

#### ConfigChange ✅

**触发时机**：配置变更
**阻塞**：否

---

#### WorktreeCreate ✅ / WorktreeRemove ✅

**触发时机**：Git 工作树创建/移除
**阻塞**：WorktreeCreate 是、WorktreeRemove 否

---

#### FileChanged

**触发时机**：监视的文件变更
**Matcher**：文件名（如 `.env|.envrc`）
**阻塞**：否

**输入（额外字段）**：
```json
{
  "file_path": "string — 变更文件路径"
}
```

---

#### CwdChanged

**触发时机**：工作目录变更
**阻塞**：否

**输入（额外字段）**：
```json
{
  "new_cwd": "string — 新工作目录"
}
```

---

#### InstructionsLoaded

**触发时机**：加载 CLAUDE.md 或 .claude/rules/*.md
**Matcher**：`session_start` | `nested_traversal` | `path_glob_match` | `include` | `compact`
**阻塞**：否

**输入（额外字段）**：
```json
{
  "file_path": "string — 加载的文件路径",
  "memory_type": "User | Project | Local | Managed",
  "load_reason": "session_start | nested_traversal | path_glob_match"
}
```

---

#### MessageDisplay

**触发时机**：消息显示
**阻塞**：否

**输出（hookSpecificOutput）**：
```json
{
  "hookEventName": "MessageDisplay",
  "displayContent": "string — 替换显示内容"
}
```

---

#### Elicitation

**触发时机**：MCP 服务器请求用户输入
**Matcher**：MCP 服务器名
**阻塞**：是

**输出（hookSpecificOutput）**：
```json
{
  "hookEventName": "Elicitation",
  "action": "accept | decline | cancel",
  "content": { "field1": "value" }
}
```

---

#### ElicitationResult

**触发时机**：Elicitation 完成后
**阻塞**：否

---

#### TaskCreated

**触发时机**：任务创建
**阻塞**：否

---

#### UserPromptExpansion

**触发时机**：用户提示扩展
**阻塞**：否

---

## 附录 B：完整 JSON 字段参考

### B.1 AgentEvent 完整字段（PeachyPet 接收格式）

以下是 PeachyPet 的 `AgentEvent` 模型定义的所有字段，JSON key 使用 snake_case：

```json
{
  "hook_event_name": "string — 必填，事件名称",
  "session_id": "string? — 会话 ID",
  "cwd": "string? — 当前工作目录",
  "permission_mode": "string? — 权限模式",
  "transcript_path": "string? — transcript 文件路径",

  "tool_name": "string? — 工具名（PreToolUse/PostToolUse/PermissionRequest 等）",
  "tool_input": "object? — 工具输入参数（键值对，值为任意类型）",
  "tool_response": "object? — 工具输出（PostToolUse/PostToolUseFailure）",
  "tool_use_id": "string? — 工具调用唯一 ID",

  "message": "string? — 通知消息文本",
  "title": "string? — 通知标题",
  "notification_type": "string? — 通知类型",

  "source": "string? — 来源（SessionStart: startup/resume/clear/compact）",
  "reason": "string? — 原因（Stop: finished/interrupted, SessionEnd, StopFailure）",
  "model": "string? — 使用的 LLM 模型 ID",

  "stop_hook_active": "boolean? — Stop hook 是否被触发",
  "last_assistant_message": "string? — 最后一条助手消息",

  "agent_id": "string? — 子代理 ID",
  "agent_type": "string? — 子代理类型（Explore 等）",

  "task_id": "string? — 任务 ID",
  "task_subject": "string? — 任务描述",

  "permission_suggestions": "array? — 权限建议列表",

  "terminal_pid": "number? — 终端应用进程 PID（由 hook 脚本注入）",
  "shell_pid": "number? — Shell 进程 PID（由 hook 脚本注入）"
}
```

### B.2 permission_suggestions 结构

```json
[
  {
    "type": "addRules",
    "destination": "session | localSettings",
    "behavior": "allow",
    "rules": [
      {
        "toolName": "Bash",
        "ruleContent": "/Users/dev/project/**"
      }
    ]
  },
  {
    "type": "setMode",
    "mode": "acceptEdits | plan"
  }
]
```

### B.3 tool_input 典型结构

#### Bash
```json
{ "command": "npm test" }
```

#### Edit
```json
{
  "file_path": "/src/app.ts",
  "old_string": "const x = 1",
  "new_string": "const x = 2"
}
```

#### Write
```json
{
  "file_path": "/src/new-file.ts",
  "content": "export default function() {}"
}
```

#### Read
```json
{
  "file_path": "/src/app.ts",
  "limit": 100,
  "offset": 0
}
```

#### Glob
```json
{ "pattern": "src/**/*.ts" }
```

#### Grep
```json
{
  "pattern": "TODO",
  "path": "src/",
  "include": "*.ts"
}
```

#### AskUserQuestion
```json
{
  "questions": [
    {
      "question": "Which approach should we use?",
      "header": "Approach",
      "options": [
        { "label": "Option A", "description": "Description of A" },
        { "label": "Option B", "description": "Description of B" }
      ],
      "multiSelect": false
    }
  ]
}
```

#### Agent
```json
{
  "description": "Research code patterns",
  "prompt": "Find all usages of...",
  "subagent_type": "Explore"
}
```

#### WebFetch
```json
{
  "url": "https://example.com",
  "prompt": "Extract the main content"
}
```

#### WebSearch
```json
{
  "query": "React hooks best practices 2026"
}
```

### B.4 PermissionRequest 响应完整格式

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow | deny",
      "updatedInput": {
        "command": "modified-command"
      },
      "updatedPermissions": [
        {
          "type": "addRules",
          "destination": "localSettings",
          "behavior": "allow",
          "rules": [
            { "toolName": "Bash", "ruleContent": "pattern" }
          ]
        }
      ]
    }
  }
}
```

### B.5 Hook 脚本注入的额外字段

hook-sender.sh 在转发前会将以下字段注入到 JSON 末尾：

```json
{
  "...原始字段...",
  "terminal_pid": 12345,
  "shell_pid": 12346
}
```

**识别的终端应用**：Terminal、iTerm2、wezterm-gui、kitty、Cursor、Code（VS Code）、Windsurf、ghostty、alacritty、Warp、Zed、pycharm、idea、webstorm、goland、clion、phpstorm、rubymine、rider、Claude

**识别的 Shell**：zsh、bash、fish、sh、nu、pwsh、elvish（含 `-zsh`、`-bash` 等 login shell 变体）

---

## 参考资料

- Claude Code Hooks 官方文档：https://code.claude.com/docs/en/hooks
- PeachyPet 源码：`Sources/Services/HookInstaller.swift`、`Sources/Services/LocalServer.swift`
- Claude Code settings.json 配置规范：`~/.claude/settings.json`
