import AppKit
import usageBarCore
import usageBarProviders

// 注册 5 个 provider
UsageBarProviders.registerAll()

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
