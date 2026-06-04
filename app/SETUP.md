# usageBar 工程使用说明

## 一、当前形态（P1）

**SwiftPM 命令行工程**，跑出来是 CLI，输出 7 个 provider 的 token 用量统计。
P2 会升级为 NSStatusItem 菜单栏 App。

```
app/
├── Package.swift
├── Sources/
│   ├── usageBar/          主入口（main.swift，CLI 形态）
│   ├── usageBarCore/      协议 + 数据模型 + Pricing 表
│   └── usageBarProviders/ 7 个 provider 实现
└── Tests/usageBarCoreTests/  单测
```

## 二、快速开始

需要：macOS 14+、Swift 6.0+（Xcode 15+ 自带）

```bash
cd usageBar/app
swift build         # 编译
swift run usageBar  # 默认 today
swift run usageBar today
swift run usageBar week
swift run usageBar month
swift run usageBar all
swift test          # 跑单测（pricing 计算 + TimeWindow）
```

## 三、Xcode 打开调试

```bash
cd usageBar/app
open Package.swift   # Xcode "Open Package..."
```

在 Xcode 里：
- 顶部 scheme 选 `usageBar`（黄色 macOS app 图标）
- Cmd+R 跑会输出 CLI
- Cmd+U 跑测试

## 四、添加新 Provider（5 步）

1. 在 `Sources/usageBarProviders/` 新建 `XxxProvider.swift`
2. 实现 `UsageProvider` 协议（参考 `WukongProvider.swift`，简单 flat jsonl 是最易上手的模板）
3. 实现 `fetchHistoricalStats(window:) async throws -> UsageStats`
4. 在 `ProvidersBootstrap.swift` 的 `registerAll()` 里加一行
5. `swift run usageBar today` 验证

## 五、数据准确性验证

跟 `references/external/ai-token-stats.sh` 输出对比：

```bash
# 参考脚本
references/external/ai-token-stats.sh today

# usageBar
cd usageBar/app && swift run usageBar today
```

**当前已知差异（2026-05-20 P1 验证）**：

| Provider | 我们 | 参考脚本 | 真实数据 | 说明 |
|---|---|---|---|---|
| Claude (订阅+cc-api 合计) | 619 次 | 610 次 | **625** | usageBar 比参考脚本多 9 次 / 更接近真实，怀疑参考脚本 `xargs cat \| node` 因 stdin buffer 截断丢失部分记录 |
| Codex | ✅ 一致 | ✅ 一致 | - | 累计值差分算法已验证 |
| 悟空 | ✅ $10.99 | ✅ $10.99 | - | deepseek-v4-flash fallback 到 sonnet 价（与参考脚本一致） |

> 偏差排查方法：`find ~/.claude/projects -name "*.jsonl" -not -path "*/subagents/*" -type f | xargs cat | jq -c 'select(.type == "assistant" and .message.usage and (.timestamp | startswith("2026-05-20")))' | wc -l`

## 六、P2 升级路径：CLI → 菜单栏 App

当前 `main.swift` 是 CLI 入口。要升级为 NSStatusItem 菜单栏 App：

1. 把 `main.swift` 改为 `usageBarApp.swift`（带 `@main`）
2. 新增 `AppDelegate.swift` —— 调用 `NSApp.setActivationPolicy(.accessory)`
3. 新增 `StatusBarController.swift` —— `NSStatusBar.system.statusItem(...)` + `NSPopover`（直接抄 `references/cc-usage-bar/CCUsageBar/CCUsageBar/StatusBarController.swift`）
4. 新增 `UsageView.swift`（SwiftUI 列表，遍历 `ProviderRegistry.all` 展示）
5. 添加 `Sources/usageBar/Resources/Info.plist`，设置 `LSUIElement = true`（隐藏 Dock 图标）
6. `Package.swift` 已经在 `.executableTarget(name: "usageBar", ...)` 配了 `resources: [.process("Resources")]`，Info.plist 自动打包
7. `swift build` 产出二进制，再用脚本打 `.app` bundle

`.app` 打包脚本（待写）：
```bash
APP="usageBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/usageBar "$APP/Contents/MacOS/"
cp Sources/usageBar/Resources/Info.plist "$APP/Contents/"
# Assets 用 actool 编译
open "$APP"
```

## 七、P2 1a 路径：PTY spawn `claude /usage`

ClaudeCodeSubscriptionProvider 需要补 `fetchRealtimeQuota()` 的实现：

1. 直接抄 `references/cc-usage-bar/CCUsageBar/CCUsageBar/UsageViewModel.swift`
2. PTY spawn `claude` 二进制
3. 发 `/usage` 命令
4. 解析 ANSI 输出抓配额数字（5h 窗口、本周 Opus 等）
5. 终止子进程
6. 返回 `RealtimeQuota`

注意陷阱（cc-usage-bar 已踩过）：
- macOS PTY 用 `posix_openpt` + `grantpt` + `unlockpt` + `ptsname`
- Swift 里 `fork()` 不可用，要用 `dlsym` 绕开
- `WIFEXITED` / `WEXITSTATUS` 是 C 宏，要手写
- Ink REPL 优化重绘，需要触发 SIGWINCH 强制全量渲染

## 八、P3 分发打包（4b 触发后做）

- Sparkle 自动更新（参考 `references/CodexBar/` 的 `appcast.xml` 和 `Scripts/`）
- Developer ID 签名 + notarytool 公证
- Homebrew Cask 发布
- 触发条件见根 `README.md` 的 "分发演进提醒"

## 九、清理

```bash
swift package clean   # 清编译产物
rm -rf .build .swiftpm Packages
```
