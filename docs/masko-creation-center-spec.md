# Masko 创作中心规格

## 目标

把 PeachyPet 的 Masko 管理从远程 URL 配置升级为本地优先的创作、验证、运行和备份流程。第一版面向个人创作，不包含公开发布、账号、审核或素材托管。

## 核心契约

- 创作草稿与运行时 `PeachyAnimationConfig` 分离。
- 每个状态有一个锚点帧、一条循环视频；循环从锚点出发并回到锚点。
- 转场从源状态锚点到目标状态锚点。
- MVP 默认只生成 `Idle <-> 其他状态` 的枢纽转场。
- 编译配置用 Any State 条件选择目标状态；非 Idle 状态之间经 Idle 枢纽路由。
- 生成素材保存于 Application Support，而不是依赖远程链接或临时缓存。
- API Key 保存于 macOS Keychain，不进入项目、日志或导出包。

## 用户流程

1. 创建项目，选择角色参考图、风格提示词和状态。
2. 生成并预览各状态锚点、循环视频和 Idle 枢纽转场。
3. 对素材执行存在性、编码、首尾帧和锚点匹配校验。
4. 编译为现有动画状态机配置并激活。
5. 将完整项目导出为 `.masko` 本地包，或从该包恢复。

## Provider

- 提供统一图片/视频生成接口。
- 内置本地 Mock Provider，保证无网络时可走通完整流程。
- 提供可配置 HTTP Provider，API Key 从 Keychain 注入。
- 提供实验性的 QWork Sidecar Provider，复用其精确报价、异步媒体任务、轮询和受保护下载契约。
- MCP 适配保留相同接口，但真实 MCP 工具契约和模型质量验证属于后续 Block。

### 自定义 HTTP / MCP Bridge 契约

图片和视频端点均接收 `POST application/json`。请求包含 `kind`、`model`、`prompt`，以及 base64 编码的参考帧：

- 锚点：`referenceBase64`、可选 `styleReferenceBase64`。
- 循环：相同的 `startFrameBase64`、`endFrameBase64` 与 `durationSeconds`。
- 转场：源状态 `startFrameBase64`、目标状态 `endFrameBase64` 与 `durationSeconds`。

响应支持内嵌数据或下载地址：

```json
{"dataBase64":"...","fileExtension":"png"}
```

```json
{"downloadURL":"https://...","fileExtension":"mov"}
```

视频必须使用 HEVC Alpha 编码；编码不符、没有透明 alpha 或端点与锚点不匹配时，项目进入 Block，不会编译为 Ready Mascot。

### QWork Sidecar 契约（实验）

- 使用独立的 Base URL、视频模型、认证请求头和 Keychain 凭据，不覆盖 Custom API 配置。
- 新建、继续生成和重新生成前都请求 `POST sidecar/media/quotes`；只有 `exact=true` 且 `operation=image_to_video` 才展示本批次费用确认，用户取消或报价不精确时不创建媒体任务。
- 费用授权只保存在本次生成的内存中。每条视频创建前重新报价；当前单价超过用户已确认上限时立即停止，批次结束后清除授权。
- 确认后按 `POST sidecar/media/videos` → `GET sidecar/media/tasks/{id}` → 受保护的 `downloadPath` 顺序获取视频，下载请求继续携带同一认证头。
- 认证值是 QWork Sidecar 的完整短期请求头值（例如 `Bearer …`），可能过期；PeachyPet 不持有 QWork 会话 Cookie，也不绕过 QWork 登录换取长期凭据。
- QWork 当前不提供 Masko 所需的图生图锚点生成，因此状态锚点直接保留用户角色参考图。
- 当前 QWork 图生视频只接收一个参考帧、固定 5 秒并输出 H.264 MP4，不能证明循环末帧或转场目标帧匹配，也不满足 HEVC Alpha。下载完成后仍执行现有严格校验，不合格结果保持 Block，禁止用补帧或转码伪造 Ready。

## 验收

- App 重启和断网后，本地 Masko 仍能播放。
- 生成中断后可从已有素材继续。
- `.masko` 导出后再导入，项目和素材哈希一致。
- 编译结果包含状态自循环边及已选择的转场边，素材使用本地文件 URL。
- 不合格素材不能进入 Ready 状态。
- 完整测试和 release 构建通过。

## 暂不包含

- 公开社区发布、账号、审核、远端存储。
- 所有状态两两直连的自动生成。
- 循环中任意时刻无损打断；仅创作中心编译的配置在循环边界切换，旧 Masko 保持原有行为。
- 真实模型效果与成本验收。
- QWork 长期认证、双端点约束生成、HEVC Alpha 输出或经验证的透明背景后处理。
