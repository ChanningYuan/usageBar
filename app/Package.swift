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
        // 协议层：UsageProvider 协议、数据模型、Pricing
        .target(
            name: "usageBarCore",
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
            dependencies: ["usageBarCore"],
            path: "Tests/usageBarCoreTests"
        ),
    ]
)
