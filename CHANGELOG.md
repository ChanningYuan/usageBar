# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/) 与 [语义化版本](https://semver.org/lang/zh-CN/)。

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

[0.2.0]: https://github.com/ChanningYuan/usageBar/releases/tag/v0.2.0
[0.1.0]: https://github.com/ChanningYuan/usageBar/releases/tag/v0.1.0
