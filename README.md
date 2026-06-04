# usageBar

> macOS 菜单栏工具，聚合显示多个 AI 编程工具（Claude Code / Codex / Qoder / 悟空 等）的 token 用量，全本地直读、零配置。

**Swift 6 · macOS 14+**

在 macOS 状态栏一眼看到你今天 / 近 7 天 / 近 30 天 / 累计在各个 AI 编程工具上烧了多少 token。所有数据都从各工具落在本地的会话记录（jsonl / SQLite）直接读取，**不联网、不抓包、装上即用**（Cursor 除外，见下）。

## 支持的 Provider

| Provider | 数据源 | 说明 |
|---|---|---|
| Claude Code（订阅） | `~/.claude/projects/**/*.jsonl` | 按 `message.id` 前缀 `msg_01` 识别 Anthropic 直连 |
| Claude Code（API） | 同上 | `msg_vrtx_` / `msg_bdrk_` 前缀（Vertex / Bedrock 代理） |
| Qoder（CLI） | `~/.qoder/projects/**/*.jsonl` | npm `qodercli` 1.0.x+ transcript，完整 4 列 |
| Qoder（Work） | `~/Library/Application Support/QoderWork/logs/<ts>/main.log` | 增量 mirror 到本地 jsonl，精确 input/output 两列 |
| Qoder（IDE） | `~/Library/Application Support/Qoder/SharedClientCache/.../local.db` | 直读 SQLite `chat_message.token_info` |
| Codex（OpenAI） | rollout jsonl | **累计值**，跨窗口做差分 |
| 悟空 | 本地 jsonl | flat 结构，毫秒时间戳 |
| WorkBuddy | `~/.workbuddy/projects/**/*.jsonl` | Claude Code 风格会话记录 |
| Cursor | Cursor 服务端 API | ⚠️ **唯一联网** provider，勾选才会联网拉取 |
| OpenClaw | 本地（mtime 增量） | 社区个人 AI Agent |
| Hermes | `~/.hermes/state.db` | Hermes Agent（NousResearch），SQLite |

> 各工具的 "token" 口径不完全一致（有的含 cache 拆分、有的只有 input/output），所以条形图长度是**量级参考**，不是严格同口径对比。

状态栏右键 → 偏好设置，可自定义每个 provider 的可见性。

## 安装

1. 到 [Releases](../../releases) 下载最新的 `install-usagebar.zip`
2. 解压到 AI Agent 的 skill 目录，例如 Claude Code：`~/.claude/skills/install-usagebar/`
3. 跟 AI 说"装一下 usageBar"，它会自动跑 `scripts/install.sh`（解压 .app → 清 Gatekeeper 隔离 → 拷到 `/Applications` → 启动）

诊断 / 卸载等更多用法见 [`install-usagebar/README.md`](install-usagebar/README.md)。

> ⚠️ 当前为**未签名**版本，首次打开 macOS 会拦。安装脚本已自动 `xattr -d com.apple.quarantine` 处理；若手动安装，需自行执行一次。后续计划做 Developer ID 签名 + 公证。

## 从源码编译

```bash
cd app
swift build              # 编译
swift run usageBar       # 运行
```

打包成 `.app` bundle 见 [`app/Scripts/build-app.sh`](app/Scripts/build-app.sh)，更多调试说明见 [`app/SETUP.md`](app/SETUP.md)。

### 加一个新 Provider（5 步）

1. 在 `app/Sources/usageBarProviders/` 新建 `XxxProvider.swift`
2. 实现 `UsageProvider` 协议（`WukongProvider.swift` 是最简单的 flat jsonl 模板）
3. 实现 `fetchDailyRecords()`
4. 在 `ProvidersBootstrap.swift` 的 `registerAll()` 里加一行
5. `swift run usageBar` 验证

## 工程结构

```
usageBar/
├── app/                       SwiftPM 工程
│   ├── Package.swift
│   ├── Sources/
│   │   ├── usageBar/          主 App：NSStatusItem + SwiftUI popover
│   │   ├── usageBarCore/      协议层：Provider 协议 + 数据模型 + 增量缓存
│   │   └── usageBarProviders/ 各 provider 实现
│   └── Scripts/               打包脚本
├── icon/                      App 图标资源
└── install-usagebar/          安装 / 诊断 / 卸载 skill
```

## License

[MIT](LICENSE) © ChanningYuan
