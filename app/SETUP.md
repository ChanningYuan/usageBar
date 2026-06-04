# usageBar 工程使用说明

## 一、形态

**macOS 菜单栏 App**（NSStatusItem + SwiftUI popover，`LSUIElement` 无 Dock 图标）。
启动后常驻状态栏，点击展开 popover 看各 provider 的 token 用量（今日 / 7 天 / 30 天 / 累计）。

```
app/
├── Package.swift
├── Sources/
│   ├── usageBar/          主 App：main.swift + AppDelegate + StatusBarController + SwiftUI 视图
│   ├── usageBarCore/      协议层：UsageProvider 协议 + 数据模型 + 增量缓存
│   └── usageBarProviders/ 各 provider 实现
├── Scripts/              打包脚本（build-app.sh / build-skill.sh）
└── Tests/usageBarCoreTests/  单测
```

## 二、快速开始

需要：macOS 14+、Swift 6.0+（Xcode 15+ 自带）

```bash
cd app
swift build              # 编译
swift run usageBar       # 运行（菜单栏出现图标）
swift test               # 跑单测
```

## 三、Xcode 调试

```bash
cd app
open Package.swift       # Xcode "Open Package..."
```

- 顶部 scheme 选 `usageBar`
- Cmd+R 运行 / Cmd+U 跑测试

## 四、打包分发

`build-app.sh` 一条龙：编译 release → 打 `.app` bundle → 生成两个分发产物。

```bash
cd app
./Scripts/build-app.sh
```

产物：

| 产物 | 路径 | 用途 |
|---|---|---|
| `usageBar.app` | `app/dist/usageBar.app` | 本机测试：`open app/dist/usageBar.app` |
| `usageBar.zip` | `app/dist/usageBar.zip` | **给人类**：解压双击安装的 .app |
| `install-usagebar.zip` | `install-usagebar.zip`（仓库根） | **给 AI Agent**：完整 skill 包（含 SKILL.md + 脚本 + .app） |

> `build-app.sh` 会自动把最新 `.app` 同步进 `install-usagebar/` 并重打 skill 包。
> 如果只想单独重打 skill 包，用 `./Scripts/build-skill.sh`。

把这两个 zip 传到 GitHub Releases，README 的两条安装路径就指向它们。

## 五、添加新 Provider（5 步）

1. 在 `Sources/usageBarProviders/` 新建 `XxxProvider.swift`
2. 实现 `UsageProvider` 协议（`WukongProvider.swift` 是最简单的 flat jsonl 模板）
3. 实现 `fetchDailyRecords()`
4. 在 `ProvidersBootstrap.swift` 的 `registerAll()` 里加一行
5. `swift run usageBar` 验证

## 六、清理

```bash
swift package clean
rm -rf .build .swiftpm Packages app/dist
```
