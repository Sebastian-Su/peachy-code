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

### 3. 其他可选本地化项（按需）

- `Bundle Identifier`：`com.masko.desktop`（如需与上游区分可改）
- `maskoBaseURL`：仍指向 `masko.ai`（模板拉取、Browse Skins 链接依赖，改动会影响皮肤市场功能，谨慎处理）
- App 显示名 / 图标 / URL Scheme（`masko`）：如需完整改名再处理
