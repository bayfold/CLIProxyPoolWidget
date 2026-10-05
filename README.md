# CLIProxy Pool Watch

English | [中文](#中文说明)

A small native macOS app and desktop widget for monitoring CLIProxyAPI ChatGPT/Codex and Claude account quotas.

It shows a pool overview with account availability, Plus-base remaining capacity, 5-hour quota, weekly quota, plan weights, restore forecasts, and recent request health.

> Community project. Not an official CLIProxyAPI component.

## Overview


![App overview](docs/screenshots/app-overview.png)

### Medium Widget

![Medium desktop widget](docs/screenshots/widget-medium.png)

## Features

- Native SwiftUI macOS app and WidgetKit desktop widgets
- CLIProxyAPI Management API integration
- ChatGPT `wham/usage` quota display through `/v0/management/api-call`
- Experimental Claude OAuth quota display through `/v0/management/api-call`
- 5-hour and weekly quota bars
- Optional Fable weekly quota on Claude accounts when returned by Anthropic
- Small, medium, and large widgets
- Medium widget with two quota rings and restore timing
- Large widget with overall health status
- Recent request health timeline
- Account sorting by `5h`, `Week`, or `Name`
- Optional Xiaomi MiMo Token Plan usage display
- Graphical restore forecast segment on each quota bar
- Plus / Pro Lite / Pro plan weights
- Weekly kill-line handling to avoid over-counting accounts with exhausted weekly quota
- Configurable USB/system-queue thermal receipts at 5h or Week usage milestones
- Raw ESC/POS output with one bitmap, three feed lines, and at most one cut command per receipt
- Batched usage fetching with one retry
- Local-only settings storage

## Company subscriptions mode (Bayfold fork extension)

[Management UI](https://github.com/bayfold/Cli-Proxy-API-Management-Center) ·
[Component specification](https://github.com/bayfold/Cli-Proxy-API-Management-Center/blob/company/docs/company-gateway.md) ·
[GitHub Actions OIDC specification](https://github.com/bayfold/Cli-Proxy-API-Management-Center/blob/company/docs/ci-oidc.md) (implemented; admin UI manages connected repositories and workflow trust)

This fork uses separate `com.bayfold.CLIProxyPoolWidget` app and
`com.bayfold.CLIProxyPoolWidget.WidgetExtension` bundle identifiers and a separate
widget bridge directory. It does not migrate or overwrite an installed upstream
app's settings, credentials, or snapshots. Upstream license notices are preserved.

Choose **Company subscriptions** as the source and enter your company-gateway
HTTPS origin, provider (`claude` or `codex`), and an exact allowed model ID. Connect
through Tailscale from a member-owned device; Serve supplies the member identity.
Tagged devices, CI leases, and model access keys cannot read this view. No gateway
management key, provider token, browser cookie, or standalone personal account is
needed.

The app, menu bar, and desktop widget use only the passive member-scoped
`GET /api/v1/capacity?provider=...&model=...` projection. Personal means subscriptions
you own in company-gateway. The permitted pool includes these and subscriptions
explicitly shared with you, once each. This is an access count, not a claim that
every subscription is currently eligible for native routing. Counts and individual limiting headroom are
shown; percentages from different subscriptions are never added together. Quota
observation disabled on the gateway, incomplete/stale observations, and a reset
awaiting a new observation remain unknown. A reset countdown never refills quota.

Company mode never invokes upstream provider quota calls, account management,
reset grants, Xiaomi requests, or receipt printing. Its network session has no
cookie/credential storage or HTTP cache and refuses redirects. Authentication
failures show a Tailscale/member error. Settings changes cancel pending work,
clear the displayed summary, and reject responses from earlier settings versions.
Company snapshots are deliberately not saved to disk or reused by WidgetKit:
Serve identity can change independently of app settings. A fresh passive read is
required for each new widget timeline. Already displayed OS widget timelines may
remain visible until WidgetKit refreshes them; expired observations render unknown.

Existing standalone CLIProxyAPI configuration remains supported. Existing settings
without a source field migrate to standalone mode. Its management credentials and
weighted quota views retain the upstream behavior.

Synthetic company regression (no real service or user state):

```sh
swiftc Shared/PoolModels.swift Shared/UsageParser.swift Shared/PoolAPIClient.swift Shared/PoolSummaryService.swift Tests/CompanyCapacityRegression.swift -o /tmp/company-capacity-test
/tmp/company-capacity-test
```

Full app and widget Swift source typechecking (validated with the installed
macOS15.2 SDK; the newest Command Line Tools SDK lacks the SwiftUIMacros plugin):

```sh
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk -typecheck Shared/*.swift App/*.swift
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk -typecheck Shared/*.swift Widget/CLIProxyPoolWidget.swift
```

A full signed app/widget archive still requires Xcode and local signing/app group
configuration. Command Line Tools can validate the Swift sources but do not
produce the Xcode archive.

## Automated Releases

The `Release macOS app` GitHub Actions workflow builds the app and embedded widget
for both Apple Silicon and Intel, runs the synthetic regression tests, and publishes
DMG, app ZIP and SHA-256 checksum assets when a `vMAJOR.MINOR.PATCH` tag is pushed.
For example, after committing the release changes:

```sh
git tag v0.5.1
git push origin v0.5.1
```

You can also run the workflow manually with an existing version tag. Leave
`publish` unchecked to build and download Actions artifacts without creating a
release. The `build_method` choice selects the Swift compiler fallback (default)
or the full Xcode project build. Publishing an existing release fails rather than replacing its assets.
The tag supplies the app/widget version; the workflow run number supplies the
bundle build number. Builds use the Xcode 16.4 toolchain on `macos-15` and need no Apple signing
secrets. These are community builds with ad-hoc signatures, without Apple
notarization; the unsigned-build installation notes below still apply.

Run the same release packaging locally with full Xcode:

```sh
scripts/test.sh
RELEASE_VERSION=0.5.0 scripts/build-release.sh
```

For a Mac with only Command Line Tools, the local fallback compiles the same Swift
sources for both architectures and packages the app/widget directly. It generates
an `.icns` icon instead of Xcode's compiled asset catalog. Select a compatible SDK
if your default SDK lacks the SwiftUI macro plugin:

```sh
MACOS_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk \
  RELEASE_VERSION=0.5.0 scripts/build-release.sh --command-line-tools
```

Artifacts are written to `dist/`. Packaging does not launch or install the app,
read user settings, or contact a provider. Both build paths are available in CI; tag pushes use the compiler fallback. To publish the workflow itself, commit and push `.github/workflows/`,
`scripts/`, and the shared Xcode scheme alongside this documentation.

## How It Works

The app uses the same CLIProxyAPI Management API flow as the web control panel.

First it reads auth files:

```http
GET /v0/management/auth-files
Authorization: Bearer <management-key>
```

Then, for selected Codex/OpenAI-like accounts, it calls ChatGPT usage through CLIProxyAPI:

```http
POST /v0/management/api-call
Authorization: Bearer <management-key>
Content-Type: application/json

{
  "auth_index": "<auth_index>",
  "method": "GET",
  "url": "https://chatgpt.com/backend-api/wham/usage",
  "header": {
    "Authorization": "Bearer $TOKEN$",
    "Content-Type": "application/json",
    "User-Agent": "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal",
    "Chatgpt-Account-Id": "<chatgpt_account_id>"
  }
}
```

CLIProxyAPI replaces `$TOKEN$` with the selected account token.
The Codex usage request intentionally mirrors the web management panel's quota request headers. In particular, the CLI-style `User-Agent` avoids ChatGPT's browser JavaScript/cookie challenge that can occur with generic browser headers. `Chatgpt-Account-Id` is included when the auth file exposes `id_token.chatgpt_account_id`.

For Claude OAuth accounts, the app forwards `GET https://api.anthropic.com/api/oauth/usage` through the same `/v0/management/api-call` endpoint with `Authorization: Bearer $TOKEN$` and `anthropic-beta: oauth-2025-04-20`. Claude API-key entries are excluded because 5-hour and weekly subscription limits require OAuth. Anthropic's usage endpoint is not a public API contract, so this integration is experimental and surfaces upstream errors instead of treating them as zero quota.

Optionally, the app can also read Xiaomi MiMo Token Plan usage directly from:

```http
GET https://platform.xiaomimimo.com/api/v1/tokenPlan/usage
GET https://platform.xiaomimimo.com/api/v1/tokenPlan/detail
Cookie: <platform cookie>
X-Timezone: Asia/Shanghai
```

Paste the platform cookie into the app's `Xiaomi Token Plan` settings section, or use `Capture Cookie` to sign in through the built-in browser and fill it automatically. The app uses only the usage/detail endpoints and does not call the API key endpoints.

## Thermal Quota Receipts

The app can print a receipt whenever pooled 5h or Week usage crosses a configured milestone. Select a macOS printer queue, interval, paper width, monitored windows, partial cut, and optional quiet hours in the app.

Thermal output bypasses driver pagination and is sent in CUPS raw mode as one raster bitmap, three feed lines, and at most one `GS V` cut command. The app serializes receipt submissions and refuses to enqueue a new receipt when the selected queue is stopped, offline, or already has unfinished jobs. This prevents old queued pages or overlapping submissions from producing repeated cuts.

Automatic receipts require live refresh and the app to remain running. The first observation establishes a baseline and does not print retroactively. Missing quota data preserves the current milestone ledger, and an interrupted submission is marked as unknown instead of being retried automatically.

## Install

1. Download `CLIProxyPoolWidget.dmg` from Releases.
2. Open the DMG.
3. Drag `CLIProxyPoolWidget.app` to `Applications`.
4. Open the app and configure:
   - Pool URL
   - Management key
   - Refresh options
   - Plan weights
5. Click `Test Fetch`.
6. Add the `CLIProxy Pool` widget from macOS desktop widget editing.

Unsigned community builds may require extra macOS confirmation on first launch:

```bash
xattr -dr com.apple.quarantine /Applications/CLIProxyPoolWidget.app
```

Unsigned builds should only be installed from trusted sources.

## Build From Source

Requirements:

- macOS 14 or newer
- Xcode 16 or newer

Build from Terminal:

```bash
xcodebuild \
  -scheme CLIProxyPoolWidget \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<your-team-id> \
  build
```

Create a DMG:

```bash
mkdir -p dist
hdiutil create \
  -volname "CLIProxyPoolWidget" \
  -srcfolder .build/DerivedData/Build/Products/Release/CLIProxyPoolWidget.app \
  -ov \
  -format UDZO \
  dist/CLIProxyPoolWidget-0.5.0.dmg
```

The app bundle does not include a locally configured Management key by default. The key is stored at runtime in macOS user defaults on the user's machine.

## Widgets

The widget extension supports three sizes:

- Small: compact balance rows for `5h` and `Week`.
- Medium: left `5h` ring, center restore card, right `Week` ring.
- Large: quota rows, plan breakdown, and overall health status.

The current project leaves `PoolWatchConstants.appGroupID` empty and uses its local widget-container bridge. A fork that configures an App Group must add the same entitlement to both targets and use a provisioning profile that allows it.

## Settings And Privacy

Settings are stored locally on the user's Mac.

- The app stores settings in normal app `UserDefaults`.
- The Management key is not sent anywhere except to the configured CLIProxyAPI Management endpoint.
- This project does not use third-party analytics or telemetry.
- The Xiaomi platform cookie, when enabled, is sent only to `platform.xiaomimimo.com` usage/detail endpoints.

The Management key is currently stored in user defaults for local convenience. For stronger security, a future version should move the key to Keychain.

## Quota Model

The pool summary shows two common quota windows:

- `5h`: primary short window
- `Week`: weekly or secondary window

Claude account rows can also show a separate `Fable` weekly window. It is not merged into the ordinary Week balance.

Each quota bar has two visual layers:

- Solid segment: current remaining quota
- Translucent segment: next grouped restore amount, projected to the quota level after the next restore batch

Progress colors:

- Red: 0-20% remaining
- Yellow: 20-70% remaining
- Green: 70-100% remaining

Default Plus-base weights:

- Plus: `1x`
- Pro Lite: `10x`
- Pro: `20x`

If an account's weekly quota falls below the configured kill line, it does not contribute to total remaining capacity. The account row still shows the raw 5-hour bar in a muted state with `weekKILL`.

The pool-level `5h` balance uses the raw 5-hour remaining quota for accounts that are not week-killed. Weekly quota is used as a kill switch, not as a cap on ordinary 5-hour restore calculation.

Quota or rate-limit responses from `/api-call` are treated as quota state when they include reset information. They do not automatically mean the account is unavailable.

## Roadmap

- Keychain storage for the Management key
- Signed and notarized release workflow
- Multiple pool profiles
- Custom account labels

## License

MIT License. See [LICENSE](LICENSE).

---

# 中文说明

[English](#cliproxy-pool-watch) | 中文

CLIProxy Pool Watch 是一个简单的原生 macOS 应用和桌面小组件，用来监控 CLIProxyAPI 里的 ChatGPT/Codex 和 Claude 账号额度。

它提供主应用 overview 和 WidgetKit 桌面小组件：账号可用状态、Plus 基准剩余额度、5 小时额度、周额度、套餐权重、下一批恢复预测，以及近期请求健康状态。

> 社区项目，不是 CLIProxyAPI 官方组件。

## 概览

![应用概览](docs/screenshots/app-overview.png)

### 中号桌面小组件

![中号桌面小组件](docs/screenshots/widget-medium.png)

## 功能

- 原生 SwiftUI macOS 应用和 WidgetKit 桌面小组件
- 接入 CLIProxyAPI Management API
- 通过 `/v0/management/api-call` 获取 ChatGPT `wham/usage` 额度
- 通过 `/v0/management/api-call` 实验性获取 Claude OAuth 额度
- 显示 5 小时额度和周额度
- Anthropic 返回时显示独立的 Fable 周额度
- 支持小号、中号、大号桌面小组件
- 中号小组件显示两个额度圆环和恢复时间
- 大号小组件显示整体健康状态
- 近期请求健康时间线
- 账号可按 `5h`、`Week`、`Name` 排序
- 可选显示小米 MiMo Token Plan 用量
- 每条额度进度条显示图形化恢复预测段
- Plus / Pro Lite / Pro 套餐权重
- 支持周额度 kill line，避免周额度耗尽的账号造成总额度虚高
- 可在 5h 或 Week 用量跨档时，通过 USB/系统打印队列输出热敏额度小票
- ESC/POS raw 输出固定为一个位图、进纸三行、每张小票最多一次切纸
- 分批拉取 usage，并在失败时重试一次
- 设置只保存在本机

## 工作原理

应用使用和 CLIProxyAPI Web 管理面板类似的 Management API 流程。

首先读取 auth files：

```http
GET /v0/management/auth-files
Authorization: Bearer <management-key>
```

然后对选中的 Codex/OpenAI 类账号，通过 CLIProxyAPI 请求 ChatGPT usage：

```http
POST /v0/management/api-call
Authorization: Bearer <management-key>
Content-Type: application/json

{
  "auth_index": "<auth_index>",
  "method": "GET",
  "url": "https://chatgpt.com/backend-api/wham/usage",
  "header": {
    "Authorization": "Bearer $TOKEN$",
    "Content-Type": "application/json",
    "User-Agent": "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal",
    "Chatgpt-Account-Id": "<chatgpt_account_id>"
  }
}
```

CLIProxyAPI 会把 `$TOKEN$` 替换为对应账号的 token。
Codex usage 请求会刻意对齐 Web 管理面板里的 quota 请求头。尤其是 CLI 风格的 `User-Agent`，可以避开 generic browser header 触发的 ChatGPT JavaScript/cookie challenge。只要 auth file 里存在 `id_token.chatgpt_account_id`，应用就会带上 `Chatgpt-Account-Id`。

Claude OAuth 账号会通过同一个 `/v0/management/api-call` 转发 `GET https://api.anthropic.com/api/oauth/usage`，请求头使用 `Authorization: Bearer $TOKEN$` 和 `anthropic-beta: oauth-2025-04-20`。普通 Claude API Key 没有 5 小时和周订阅额度，因此不会走这条请求。Anthropic usage endpoint 不是公开稳定 API，所以当前接入标记为实验性；上游错误会直接显示，不会被误报成额度为零。

应用也可以选择直接读取小米 MiMo Token Plan 用量：

```http
GET https://platform.xiaomimimo.com/api/v1/tokenPlan/usage
GET https://platform.xiaomimimo.com/api/v1/tokenPlan/detail
Cookie: <platform cookie>
X-Timezone: Asia/Shanghai
```

把平台 cookie 粘贴到应用的 `Xiaomi Token Plan` 设置区即可，也可以点 `Capture Cookie` 通过内置浏览器登录并自动回填。应用只请求 usage/detail 接口，不会调用 API key 接口。

## 热敏额度小票

池子 5h 或 Week 已用额度跨过配置档位时，App 可以自动打印一张汇报。在设置中可以选择 macOS 打印队列、步进、纸宽、监控窗口、半切以及安静时段。

热敏输出绕过驱动分页，使用 CUPS raw 模式发送：一个位图、进纸三行、最多一个 `GS V` 切纸命令。所有小票提交会串行执行；如果队列已停用、离线或仍有未完成任务，App 会拒绝加入新任务，避免旧分页任务或并发提交再次造成连续切纸。

自动小票依赖实时刷新，并要求 App 保持运行。第一次观测只建立基线，不会补打旧档位；临时缺少额度数据不会清空当前账本；提交过程中断后会标记为“结果未知”，不会自动重复打印。

## 安装

1. 从 Releases 下载 `CLIProxyPoolWidget.dmg`。
2. 打开 DMG。
3. 把 `CLIProxyPoolWidget.app` 拖到 `Applications`。
4. 打开应用并配置：
   - Pool URL
   - Management key
   - 刷新选项
   - 套餐权重
5. 点击 `Test Fetch`。
6. 在 macOS 桌面编辑小组件，添加 `CLIProxy Pool`。

未签名的社区构建第一次打开时，macOS 可能需要额外确认：

```bash
xattr -dr com.apple.quarantine /Applications/CLIProxyPoolWidget.app
```

未签名构建只应从可信来源安装。

## 从源码构建

要求：

- macOS 14 或更新版本
- Xcode 16 或更新版本

用 Terminal 构建：

```bash
xcodebuild \
  -scheme CLIProxyPoolWidget \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<your-team-id> \
  build
```

创建 DMG：

```bash
mkdir -p dist
hdiutil create \
  -volname "CLIProxyPoolWidget" \
  -srcfolder .build/DerivedData/Build/Products/Release/CLIProxyPoolWidget.app \
  -ov \
  -format UDZO \
  dist/CLIProxyPoolWidget-0.5.0.dmg
```

默认情况下，app bundle 不会包含本地配置过的 Management key。key 是用户运行应用后保存在自己 Mac 的 user defaults 里。

## 桌面小组件

Widget extension 支持三种尺寸：

- 小号：紧凑显示 `5h` 和 `Week` 两条额度。
- 中号：左边 `5h` 圆环，中间恢复卡片，右边 `Week` 圆环。
- 大号：额度、套餐分布、整体健康状态。

当前项目的 `PoolWatchConstants.appGroupID` 留空，使用本地 widget container bridge。若 fork 后自行配置 App Group，需要为两个 target 添加相同 entitlement，并使用允许该 App Group 的 provisioning profile。

## 设置与隐私

设置保存在用户本机。

- 应用把设置保存在普通 app `UserDefaults`。
- Management key 只会发送到用户配置的 CLIProxyAPI Management endpoint。
- 启用小米 Token Plan 后，平台 cookie 只会发送到 `platform.xiaomimimo.com` 的 usage/detail 接口。
- 本项目没有第三方分析或遥测。

目前 Management key 为了本地使用方便，仍保存在 user defaults。更安全的后续版本应该改用 Keychain。

## 额度模型

池子汇总显示两个通用额度窗口：

- `5h`：短周期主窗口
- `Week`：周额度或 secondary window

Claude 账号行还可以显示独立的 `Fable` 周额度；它不会混入普通 Week 汇总。

每条额度条有两层图形：

- 实色段：当前剩余额度
- 半透明段：下一批恢复额度，表示恢复后会到达的位置

进度条颜色：

- 红色：剩余 0-20%
- 黄色：剩余 20-70%
- 绿色：剩余 70-100%

默认 Plus 基准权重：

- Plus：`1x`
- Pro Lite：`10x`
- Pro：`20x`

如果某个账号的周额度低于配置的 kill line，它不会计入总剩余额度。账号行仍会以灰色显示原始 5 小时进度，并标记 `weekKILL`。

池子级别的 `5h` 余额会使用未被 week kill 的账号的原始 5 小时剩余额度。周额度只作为 kill switch，不会在普通情况下截断 5 小时恢复额度。

如果 `/api-call` 返回的是额度不足或 rate limit，并且响应里包含 reset 信息，应用会把它当作额度状态解析，不会自动认为账号不可用。

## Roadmap

- 用 Keychain 保存 Management key
- 签名和 notarized 发布流程
- 多个 pool 配置
- 自定义账号名称

## License

MIT License. See [LICENSE](LICENSE).
