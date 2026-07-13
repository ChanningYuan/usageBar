import AppKit
import usageBarCore
import usageBarProviders

// 悬浮提示(tooltip)0 延迟——AppKit 默认 ~2-3s 太慢。读 NSInitialToolTipDelay(毫秒)，
// 必须在任何 tooltip 出现前设置。
UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

// 注册所有 provider
UsageBarProviders.registerAll()

// 价目兜底：磁盘上没有 pricing.json 缓存时（首启，或拉取一直被公司安全软件/网络拦），
// 装上安装包内置的快照，先让金额有数——总好过全员 $0。有磁盘缓存时这行是空操作，
// 且无论如何都不影响后台的强制拉取（见 RemotePricing 加固④）。
RemotePricing.shared.installBundledSnapshotIfNeeded(
    BundleIconLoader.loadData(name: "pricing-snapshot", ext: "json")
)

// 把外部 SIGTERM/SIGINT 转成 NSApp.terminate，以便走 applicationWillTerminate（持久化 cache）
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigtermSrc.setEventHandler { NSApp.terminate(nil) }
sigintSrc.setEventHandler { NSApp.terminate(nil) }
sigtermSrc.resume()
sigintSrc.resume()

// 启动 NSApp（menu bar 形态，无 Dock 图标 = .accessory）
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
