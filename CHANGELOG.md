# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/) 与 [语义化版本](https://semver.org/lang/zh-CN/)。

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

[0.3.0]: https://github.com/ChanningYuan/usageBar/releases/tag/v0.3.0
[0.2.0]: https://github.com/ChanningYuan/usageBar/releases/tag/v0.2.0
[0.1.0]: https://github.com/ChanningYuan/usageBar/releases/tag/v0.1.0
