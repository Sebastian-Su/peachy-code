# Peachy Code 本地化改造

将项目从上游 `RousselPaul/masko-code` fork 到自有仓库 `Sebastian-Su/peachy-code` 后的本地化改造记录与待办。

## 已完成

- **自动升级地址**（`Info.plist` 的 `SUFeedURL`）
  - `https://masko.ai/api/desktop/appcast`
  - → `https://raw.githubusercontent.com/Sebastian-Su/peachy-code/main/appcast.xml`
- **设置页仓库链接**（`SettingsView.swift` About 区块）
  - "Masko Website"（`masko.ai`）→ "GitHub Repository"（peachy-code 仓库）
  - 新增常量 `Constants.repoURL` 承载仓库地址
- **git remote**
  - `origin` → `https://github.com/Sebastian-Su/peachy-code.git`
  - `upstream` → `git@github.com:RousselPaul/masko-code.git`（保留原源用于同步上游）

## 待办

### 1. 替换 Sparkle 签名公钥（发布前必做）

`Info.plist` 的 `SUPublicEDKey` 仍是上游作者的 EdDSA 公钥：

```
/BVYK9Q4hZORSn/xfhu4BCCLrug5zEA5WkwXG2lgdiw=
```

自行发布更新时，更新包需用**自己的私钥**签名，此公钥也要替换成对应公钥，否则 Sparkle 签名校验失败、更新无法安装。

- 用 Sparkle 的 `generate_keys` 生成密钥对
- 私钥安全保存（不入库）
- 用生成的公钥替换 `Info.plist` 中的 `SUPublicEDKey`

### 2. 生成并发布 appcast.xml

新的 `SUFeedURL` 指向 `peachy-code/main/appcast.xml`，该文件目前不存在，自动升级无法工作。

- 用 Sparkle 的 `generate_appcast` 对发布产物生成签名后的 `appcast.xml`
- 将 `appcast.xml` 推到仓库 `main` 分支根目录（与 `SUFeedURL` 路径一致）

## 全局品牌改名（masko → peachy）

将主 App 全面 peachy 化。**已改**：

- **Swift 类型名**：`MaskoDesktopApp`→`PeachyDesktopApp`、`MaskoCollection`/`MaskoCanvas`/`MaskoAnimation*`→`Peachy*`、`MaskoDashboardView`→`PeachyDashboardView`、`MaskoEventBus`→`PeachyEventBus`
- **文件/目录**：对应源文件、`Sources/Views/Masko/`→`Sources/Views/Peachy/`、`masko-desktop.entitlements`→`peachy-code.entitlements`、`Defaults/masko.json`→`peachy.json`
- **Package.swift**：package/target 名 `masko-code`→`peachy-code`、testTarget、依赖引用
- **Info.plist**：`CFBundleExecutable`/`CFBundleName`/`CFBundleDisplayName`→`peachy-code`/`Peachy Code`、Bundle ID `com.masko.desktop`→`com.peachy.code`
- **数据目录**：`~/Library/Application Support/masko-desktop/`→`peachy-code/`、`~/.masko-desktop/`→`~/.peachy-code/`（⚠️ 已接受旧数据重置）
- **URL scheme**：`masko://`→`peachy://`（含 `handleMaskoURL`→`handlePeachyURL`、scheme 判断）
- **服务地址常量**：`maskoBaseURL`→`peachyBaseURL`，值改指 `github.com/Sebastian-Su/peachy-code`
- **预置皮肤**：默认皮肤 slug/filename `masko`→`peachy`，皮肤显示名 `Masko`→`Peachy`
- **品牌文案**：侧边栏、卸载、Onboarding、菜单等所有用户可见 "Masko"→"Peachy"，"View on masko.ai"→"View on GitHub"
- **内部标识**：`masko-copilot`→`peachy-copilot`、`masko-audio`/`masko-hook`/`masko-doctor-test`、OSLog label `ai.masko.*`→`ai.peachy.*`

### 刻意保留（改了会破坏功能）

- **`assets.masko.ai` CDN**（252 处）：预置皮肤的视频/图片真实资源地址，无对应替代，改了皮肤动画全部加载失败。
- **卸载兼容清理列表**（`SettingsView.swift`）：保留 `masko-code.plist` 等旧名，用于清理上游版本的安装残留，无害。
- **纯注释中的 masko.ai**：历史来源说明，不影响功能、不对用户可见。

## IDE 扩展改名（masko → peachy）

将两个 IDE 终端聚焦扩展彻底 peachy 化，并同步主 App 的引用契约。

**VS Code 扩展（`extensions/vscode/`）— 已完成并重打包**：
- `package.json`：`name` `peachy-terminal-focus`、`displayName` `Peachy Terminal Focus`、`publisher` `peachy`、`description`
- 用 `npx @vscode/vsce package` 重打包 → `Sources/Resources/Extensions/peachy-terminal-focus.vsix`（内部扩展 ID `peachy.peachy-terminal-focus`）
- `extension.js` 无品牌标识，未改

**JetBrains 扩展（`extensions/jetbrains/`）— 源码已改，⚠️ 产物待重编**：
- `plugin.xml`：`id` `ai.peachy.terminal-focus`、`name`、`vendor`、handler 全限定名 `ai.peachy.terminalfocus.PeachyTerminalFocusHandler`
- Kotlin：包路径目录 `ai/masko/`→`ai/peachy/`、类名 `MaskoTerminalFocusHandler`→`PeachyTerminalFocusHandler`、文件名同步
- `build.gradle.kts`：`group` `ai.peachy`、`archiveBaseName` `peachy-terminal-focus`
- `settings.gradle.kts`：`rootProject.name` `peachy-terminal-focus`
- **HTTP 路由** `/api/masko/`→`/api/peachy/`（focus/ping）

**主 App 同步（`ExtensionInstaller.swift`/`IDETerminalFocus.swift`）— 已完成**：
- `extensionId` `peachy.peachy-terminal-focus`、`jetbrainsPluginId` `ai.peachy.terminal-focus`
- 插件目录名、setup/focus URL、资源文件名 `.vsix`/`.zip`
- JetBrains HTTP 请求 URL `/api/peachy/focus`、VS Code scheme URL `peachy.peachy-terminal-focus`

### 待办：重编 JetBrains 插件 zip（必做，否则 JetBrains 聚焦失效）

`Sources/Resources/Extensions/peachy-terminal-focus-jetbrains.zip` 目前**仅文件名改了，内部 jar 仍是旧 masko 版本**（含旧类名 `MaskoTerminalFocusHandler`、旧路由 `/api/masko/`）。而主 App 现在请求 `/api/peachy/`，与旧 jar 不匹配 → JetBrains 终端聚焦在重编前会失效（VS Code 家族不受影响）。

重编步骤（需 JDK 17）：
```bash
brew install openjdk@17          # 若无 Java
cd extensions/jetbrains
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
./gradlew buildPlugin            # 产物在 build/distributions/peachy-terminal-focus-1.0.0.zip
```
重编后将产物覆盖到 `Sources/Resources/Extensions/peachy-terminal-focus-jetbrains.zip`（确认 zip 顶层目录为 `peachy-terminal-focus/`，与 `ExtensionInstaller` 里的 `pluginDir` 名一致）。

### 改名副作用（已知）

- **皮肤市场 / Browse Skins / 模板导入 / Connection Doctor 上报**：原依赖 `masko.ai` 后端，现 `peachyBaseURL` 指向 GitHub 仓库，这些远端功能失效（皮肤加载回落到本地 bundle 仍可用）。
- **旧数据**：数据目录改名后，上游版本存的 mascot/设置读不到（旧数据仍在磁盘 `masko-desktop` 目录，可手动迁移）。
- **JetBrains 聚焦**：重编 zip 前失效（见上方待办）。
