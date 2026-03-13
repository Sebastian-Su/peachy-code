## 项目总览

Masko Code 是一个运行在 macOS 菜单栏的 Swift / SwiftUI 应用，用来为 Claude Code 提供一个“悬浮吉祥物”和可视化控制面板。  
应用通过监听 Claude Code 的会话 / 工具调用事件，并在本地 HTTP 端口 `49152` 上暴露接口，与终端中的 Claude Code 会话联动。

- **平台**: macOS 14.0+，Apple Silicon（arm64）
- **语言 / 技术栈**: Swift, SwiftUI, Swift Package Manager
- **主要职责**:
  - 显示悬浮吉祥物与仪表盘（前端 UI）
  - 接收 Claude Code 钩子事件，维护会话 / 通知状态
  - 为 IDE 扩展（如 VS Code / Cursor）提供“定位到正确终端”的能力

Claude 在这个仓库中的主要任务是：**安全地扩展 Masko Code 的功能、修复 bug，并保持良好的 Swift / SwiftUI 架构与用户体验**。

---

## 代码结构与上下文

根目录关键内容（与 README 保持一致，便于你快速定位）:

- `Sources/`
  - `App/`：应用入口和生命周期管理（`@main`、`NSApplication` / `SwiftUI App` 相关）
  - `Models/`：会话、事件、Hook 配置等数据模型
  - `Services/`：本地 HTTP 服务、Claude Hook 安装器、更新检查等后台服务
  - `Stores/`：使用 `ObservableObject` / `@Published` 等实现的状态存储（会话列表、通知队列等）
  - `Views/`：SwiftUI 视图层（悬浮吉祥物、权限气泡、仪表盘、设置面板等）
  - `Utilities/`：通用工具方法和小型帮助类
  - `Resources/`：图片、图标、动画等静态资源
- `scripts/`：打包 DMG、发布相关脚本
- `vscode-extension/`：用于 VS Code / Cursor 的终端聚焦扩展

在进行修改前，优先查阅：

- `README.md`：获取功能概览、项目目标与结构说明
- `Package.swift`：了解依赖、目标与构建配置
- `.swiftlint.yml`：获取 Swift 代码风格与 lint 规则

---

## 对 Claude 的行为预期

当你在本仓库中工作时，请遵循以下原则：

1. **保持 macOS / SwiftUI 架构清晰**
   - 优先使用单向数据流（State / Store → View），避免在 View 中堆叠过多业务逻辑。
   - 新增状态尽量集中在 `Stores/` 中，通过依赖注入或环境对象传递到 `Views/`。
2. **尊重现有设计与用户体验**
   - 动画、尺寸、位置交互要尽量与现有吉祥物风格一致。
   - 避免引入会打断用户编码流的弹窗式交互，优先使用非侵入式提示（气泡、Badge、轻量提醒）。
3. **与 Claude Code 的集成要安全且可配置**
   - 编辑 `~/.claude/settings.json` 的逻辑必须谨慎：始终做幂等更新、备份旧配置、避免破坏用户已有配置。
   - 本地 HTTP 服务（端口 `49152`）应仅监听本机，避免暴露到外网。
4. **错误处理与可观测性**
   - 与文件系统、网络（本地 HTTP）、外部进程交互时，务必做错误处理并记录可调试的信息（日志或用户可见的轻量提示）。
   - 不要静默吞掉重要错误。

---

## 开发与运行

### 本地构建

推荐使用 SwiftPM 方式进行本地构建与运行：

```bash
git clone https://github.com/RousselPaul/masko-code.git
cd masko-code
swift build
swift run
```

如在 Xcode 中打开，请确保：

- 使用 macOS 14+ SDK
- 运行目标为 Apple Silicon（arm64）
- 签名 / Sandbox 配置满足访问辅助功能（Accessibility）与文件系统所需权限

### Swift 代码风格

- 遵循 `.swiftlint.yml` 中的规则；新增文件时保持相同风格（命名、缩进、空行等）。
- 函数命名应表达意图而非实现细节，避免过长的“上帝函数”。
- 复杂视图建议拆分为小型 SwiftUI 组件，放在 `Views/` 中按功能或区域分组。

---

## 典型修改场景指引

### 1. 新增或调整 UI（吉祥物 / 仪表盘）

- **优先位置**：`Sources/Views/` 下对应视图文件。
- 如果需要新的状态：
  - 在 `Stores/` 中增加字段和逻辑。
  - 通过 `@StateObject` / `@EnvironmentObject` / 依赖注入连接到 View。
- 如涉及交互（点击、悬停、快捷键）：
  - 明确该交互是否会打断用户当前工作流，尽可能保持轻量。

### 2. 处理 Claude Code Hook / 事件

- **优先位置**：`Sources/Services/` 与 `Sources/Models/`。
- 添加新事件类型时：
  - 在 `Models/` 中定义数据结构。
  - 在 `Services/` 中解析与分发。
  - 在 `Stores/` 中更新状态，再由 `Views/` 订阅并渲染。

### 3. 脚本与打包

- **优先位置**：`scripts/`。
- 所有脚本请保证：
  - 可在 macOS 14+ 默认 Shell 环境（zsh）下运行。
  - 对已有文件的修改是幂等、安全且可逆的（必要时做备份）。

---

## 对 Claude Code 工作流的建议

在本仓库工作时，推荐你遵循以下工作流：

1. **阅读上下文**
   - 首先阅读 `README.md`、`Package.swift` 和相关模块的现有代码。
2. **先写设计 / 计划，再改代码**
   - 对于非极小改动，先在 `docs/plans/` 下创建对应的设计 / 实施计划（如路径不存在，可先创建）。
3. **小步提交**
   - 每次改动保持范围小且可描述清楚，提交信息说明“为什么”而不仅是“做了什么”。
4. **运行并验证**
   - 编译并运行应用，验证吉祥物、仪表盘和与 Claude Code 的联动是否符合预期。
   - 新功能应尽量配套测试（如项目引入测试目标后）。

---

## 安全与隐私注意事项

- 不要将用户的 Claude 会话内容、终端输出等敏感信息持久化到不必要的位置。
- 不要添加任何将数据发送到远程服务器的逻辑，除非经过明确设计与许可。
- 若必须访问用户文件（如 `~/.claude/settings.json`），要：
  - 最小化读取 / 写入范围；
  - 在出错时给出清晰友好的提示，而不是直接崩溃或静默失败。

---

## 你可以假设的前置条件

在本仓库中工作时，你可以安全地假设：

- 开发者使用的是 macOS 14+ 且为 Apple Silicon 机器。
- 已安装并使用 Claude Code，`~/.claude/settings.json` 存在或可以创建。
- 项目通过 SwiftPM 构建，没有额外的第三方依赖管理工具。

如这些假设与实际环境不符，应在文档或错误提示中明确说明，并避免强依赖。

