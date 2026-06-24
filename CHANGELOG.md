# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/) 与 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.3.5] - 2026-06-24

### 修复
- **修复「Qoder (Work)」统计归零**：QoderWork 桌面 app 升级到 0.6.3 后改了 token 数据的存放位置，导致这一行从某天起一直显示 0。现已接入新数据源，并与历史数据相加，「Qoder (Work)」恢复正常统计、历史数字不丢。

## [0.3.4] - 2026-06-24

### 变更
- **DMG 安装窗口加拖拽引导**：安装窗口新增一条从应用图标指向「应用程序」文件夹的虚线引导箭头，底部加上中英双语「拖拽到右侧安装」提示；应用图标加了柔和投影，在白色背景上更清晰、更易看出是一张可拖拽的卡片。

## [0.3.3] - 2026-06-24

### 新增
- **Qoder (CLI) 用量统计一键开启**：新版 qodercli 默认不把 token 用量写到本地，导致「Qoder (CLI)」一直显示 0。现在偏好设置的 Qoder (CLI) 下会引导一键开启（写入环境变量 `QODER_EXPOSE_TOKEN_USAGE=1`，不会动你 `~/.zshrc` 里的其它内容），开启后**新开终端**跑 qodercli 即可正常统计；可随时一键撤销。菜单弹层也会在未开启时提示「去开启」。

### 修复
- **首次运行不再误隐藏 Qoder (CLI)**：用过 qodercli 但还没开启用量统计（本地全 0）的用户，首次运行不会再把「Qoder (CLI)」这一行自动隐藏，确保能看到开启引导。

## [0.3.2] - 2026-06-17

### 新增
- **首次运行智能默认**：第一次拉到数据后，只保留有用量的 provider，零用量的自动隐藏（仅一次，不覆盖你之后的手动开关）。新用户不再一打开就是一长串空行。

### 变更
- **DMG 安装窗口美化**：图标布局/窗口大小调整，更接近常规 app 的拖拽安装界面。

## [0.3.1] - 2026-06-17

### 变更
- 自动更新弹窗等 Sparkle 界面现在**跟随系统语言**显示中文（之前固定英文）。
- 偏好设置标题栏显示**当前版本号**。

## [0.3.0] - 2026-06-17

### ⚠️ 重要变更（升级后你的数字会变化）
- **修正 Claude token 重复计数**：同一条 API 响应在流式落盘时会被写多行、usage 完全相同，旧版逐行累加导致 Claude（订阅 / API）数字虚高约 2 倍。现按 `message.id` 去重，只计一次。
  **升级后你的 Claude 数字会一次性下降约一半——这是修正虚高、不是数据丢失**，历史趋势图会出现一个明显台阶。

### 新增
- **Claude Cowork 用量统计**：扫描桌面端 Claude（`~/.claude/local-agent-mode-sessions/`）的 transcript，归入 Claude 组。
- **自动更新弹窗显示更新说明**：点"检查更新…"时直接看到这一版改了什么（自动取自本 CHANGELOG）。

### 变更
- 偏好设置里开关的开启态改为系统蓝，明暗主题下都清晰。

## [0.2.0] - 2026-06-10

### 新增
- **应用内自动更新**（基于 Sparkle）：右键菜单"检查更新…"，新版会自动提示下载安装。
  - ℹ️ 从此版起支持自动更新；早于 0.2.0 的版本需手动下载一次本版，之后即可自动更新。
- **DMG 拖拽安装包**：Releases 新增 `usageBar.dmg`，双击拖进 Applications 即可。

### 变更
- 发布版（.app / .dmg）均已 **Apple Developer ID 签名 + 公证**，双击即开，无需手动放行。

## [0.1.0] - 2026-06-04

### 新增
- 首个公开版本。macOS 菜单栏聚合显示多个 AI 编程工具的 token 用量。
- 支持 Provider：Claude Code（订阅 / API）、Qoder（CLI / Work / IDE）、Codex、悟空、WorkBuddy、Cursor、OpenClaw、Hermes。
- 今日 / 近 7 天 / 近 30 天 / 累计四视图，偏好设置可自定义各 provider 可见性。
- 全本地直读（jsonl / SQLite），零配置（Cursor 除外，需联网）。
- 安装方式：人类下载 .app / AI Agent 走 install-usagebar skill 一句话装。

[0.3.2]: https://github.com/ChanningYuan/usageBar/releases/tag/v0.3.2
[0.3.1]: https://github.com/ChanningYuan/usageBar/releases/tag/v0.3.1
[0.3.0]: https://github.com/ChanningYuan/usageBar/releases/tag/v0.3.0
[0.2.0]: https://github.com/ChanningYuan/usageBar/releases/tag/v0.2.0
[0.1.0]: https://github.com/ChanningYuan/usageBar/releases/tag/v0.1.0
