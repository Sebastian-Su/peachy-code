# PeachyPet 本地化改造

将项目从原上游 fork 到自有仓库 `Sebastian-Su/peachy-code` 后的本地化改造记录与待办。

## 已完成

- **自动升级地址**（`Info.plist` 的 `SUFeedURL`）
  - 原上游 appcast 服务地址
  - → `https://raw.githubusercontent.com/Sebastian-Su/peachy-code/main/appcast.xml`
- **设置页仓库链接**（`SettingsView.swift` About 区块）
  - 原上游官网入口 → "GitHub Repository"（peachy-code 仓库）
  - 新增常量 `Constants.repoURL` 承载仓库地址
- **git remote**
  - `origin` → `https://github.com/Sebastian-Su/peachy-code.git`
  - `upstream` → 原上游仓库（保留 remote 用于同步）

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

## 全局品牌改名（原上游品牌 → PeachyPet）

将主 App 全面 PeachyPet 化。**已改**：

- **Swift 类型名**：统一为 `PeachyDesktopApp`、`PeachyCollection`、`PeachyCanvas`、`PeachyAnimation*`、`PeachyDashboardView`、`PeachyEventBus`
- **文件/目录**：统一使用 `Sources/Views/Peachy/`、`PeachyPet.entitlements` 与 `Defaults/peachy.json`
- **Package.swift**：package、可执行 target 与 test target 统一为 `PeachyPet`
- **Info.plist**：`CFBundleExecutable`、`CFBundleName`、`CFBundleDisplayName` 与 Bundle ID 统一使用 PeachyPet 品牌
- **数据目录**：统一为 `~/Library/Application Support/PeachyPet/` 与 `~/.peachypet/`（⚠️ 已接受旧数据重置）
- **URL scheme**：统一为 `peachypet://`，入口方法为 `handlePeachyURL`
- **服务地址常量**：统一使用 `peachyBaseURL`，值指向 `github.com/Sebastian-Su/peachy-code`
- **预置皮肤**：默认皮肤 slug/filename 与显示名统一为 `peachy` / `Peachy`
- **品牌文案**：侧边栏、卸载、Onboarding、菜单等用户可见名称统一为 PeachyPet，外部入口统一指向 GitHub
- **内部标识**：音频、hook、doctor、OSLog 等内部标识统一使用 `peachy` 或 `peachypet` 前缀

### 刻意保留（改了会破坏功能）

- **原上游皮肤 CDN**：预置皮肤的视频/图片真实资源地址尚无替代，当前保留，否则动画会全部加载失败。
- **卸载兼容清理列表**（`SettingsView.swift`）：暂时保留旧版本安装残留的清理项。

## IDE 扩展改名（原上游品牌 → PeachyPet）

将两个 IDE 终端聚焦扩展彻底 peachy 化，并同步主 App 的引用契约。

**VS Code 扩展（`extensions/vscode/`）— 已完成并重打包**：
- `package.json`：`name` `peachy-terminal-focus`、`displayName` `Peachy Terminal Focus`、`publisher` `peachy`、`description`
- 用 `npx @vscode/vsce package` 重打包 → `Sources/Resources/Extensions/peachy-terminal-focus.vsix`（内部扩展 ID `peachy.peachy-terminal-focus`）
- `extension.js` 无品牌标识，未改

**JetBrains 扩展（`extensions/jetbrains/`）— 源码已改，⚠️ 产物待重编**：
- `plugin.xml`：`id` `ai.peachy.terminal-focus`、`name`、`vendor`、handler 全限定名 `ai.peachy.terminalfocus.PeachyTerminalFocusHandler`
- Kotlin：包路径目录统一为 `ai/peachy/`，类名为 `PeachyTerminalFocusHandler`，文件名同步
- `build.gradle.kts`：`group` `ai.peachy`、`archiveBaseName` `peachy-terminal-focus`
- `settings.gradle.kts`：`rootProject.name` `peachy-terminal-focus`
- **HTTP 路由** 统一为 `/api/peachy/`（focus/ping）

**主 App 同步（`ExtensionInstaller.swift`/`IDETerminalFocus.swift`）— 已完成**：
- `extensionId` `peachy.peachy-terminal-focus`、`jetbrainsPluginId` `ai.peachy.terminal-focus`
- 插件目录名、setup/focus URL、资源文件名 `.vsix`/`.zip`
- JetBrains HTTP 请求 URL `/api/peachy/focus`、VS Code scheme URL `peachy.peachy-terminal-focus`

### 待办：重编 JetBrains 插件 zip（必做，否则 JetBrains 聚焦失效）

`Sources/Resources/Extensions/peachy-terminal-focus-jetbrains.zip` 目前**仅文件名改了，内部 jar 仍是原上游版本**（含旧类名和旧路由）。而主 App 现在请求 `/api/peachy/`，与旧 jar 不匹配 → JetBrains 终端聚焦在重编前会失效（VS Code 家族不受影响）。

重编步骤（需 JDK 17）：
```bash
brew install openjdk@17          # 若无 Java
cd extensions/jetbrains
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
./gradlew buildPlugin            # 产物在 build/distributions/peachy-terminal-focus-1.0.0.zip
```
重编后将产物覆盖到 `Sources/Resources/Extensions/peachy-terminal-focus-jetbrains.zip`（确认 zip 顶层目录为 `peachy-terminal-focus/`，与 `ExtensionInstaller` 里的 `pluginDir` 名一致）。

### 改名副作用（已知）

- **皮肤市场 / Browse Skins / 模板导入 / Connection Doctor 上报**：原依赖上游后端，现 `peachyBaseURL` 指向 GitHub 仓库，这些远端功能失效（皮肤加载回落到本地 bundle 仍可用）。
- **旧数据**：数据目录改名后，上游版本存的 mascot/设置读不到，旧数据可按需手动迁移。
- **JetBrains 聚焦**：重编 zip 前失效（见上方待办）。
