// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "usageBar",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "usageBar", targets: ["usageBar"]),
        .library(name: "usageBarCore", targets: ["usageBarCore"]),
        .library(name: "usageBarProviders", targets: ["usageBarProviders"]),
    ],
    dependencies: [
        // 自动更新框架（store 外分发的标准方案）
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // zstd 官方解压代码（v1.5.7，BSD 许可，见目录里的 LICENSE），只取解压部分，编进去约 60 KB。
        // Codex 桌面版 2026-10-16 起把旧对话日志压成 `.jsonl.zst`，macOS 自带的解压框架不支持这种格式。
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            exclude: ["LICENSE"],
            cSettings: [
                .define("ZSTD_DISABLE_ASM"),           // 只要 C 实现，不编汇编（本 App 只出 arm64）
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
            ]
        ),

        // 协议层：UsageProvider 协议、数据模型、Pricing
        .target(
            name: "usageBarCore",
            dependencies: ["CZstd"],
            path: "Sources/usageBarCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),

        // 5 个 provider 的实现
        .target(
            name: "usageBarProviders",
            dependencies: ["usageBarCore"],
            path: "Sources/usageBarProviders",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),

        // 主 App（菜单栏 + popover，NSStatusItem + SwiftUI popover）
        // Info.plist 通过 linker 嵌入 __TEXT,__info_plist section
        // —— 这是 SwiftPM 跑 macOS GUI App 的标准做法（不允许 Info.plist 作 resource）
        .executableTarget(
            name: "usageBar",
            dependencies: [
                "usageBarCore",
                "usageBarProviders",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/usageBar",
            exclude: ["Info.plist"],
            resources: [
                .process("Icons"),
                // 内置价目快照：build-app.sh 每次构建从线上表 curl 刷新（零人工维护）。
                // 用途：用户机器拉不到 usagebar.cn 时兜底，避免全员 $0（见 RemotePricing 加固④）。
                .copy("pricing-snapshot.json"),
                // 内置第三方代码的许可声明（zstd 是 BSD 许可，要求随分发附上版权声明）
                .copy("ThirdPartyNotices.txt"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/usageBar/Info.plist",
                ])
            ]
        ),

        // 单测
        .testTarget(
            name: "usageBarCoreTests",
            dependencies: ["usageBarCore", "usageBarProviders"],
            path: "Tests/usageBarCoreTests"
        ),
    ]
)
