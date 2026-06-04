import AppKit
import Combine
import SwiftUI
import usageBarCore

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    let viewModel: UsageViewModel

    private var refreshTimer: Timer?
    private var clickMonitor: Any?
    private var rightClickMonitor: Any?
    private var rightClickMenu: NSMenu!
    private var titleSubscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?

    /// 后台刷新间隔：10 分钟（mtime 增量后单次成本低，但仍避免高频）
    private let refreshInterval: TimeInterval = 600

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.viewModel = UsageViewModel()
        super.init()

        configureStatusItem()
        configurePopover()
        configureRightClickMenu()
        installRightClickMonitor()
        installTitleSubscription()
        installSettingsSubscription()

        Task {
            // 1. 先从磁盘读 mtime 缓存（< 100ms）
            await FileMtimeCache.shared.loadFromDisk()
            // 2. 触发第一次 refresh（命中持久化缓存的话 < 1s 完成）
            await viewModel.refresh()
            startRefreshTimer()
        }
    }

    /// 把菜单栏 title 的更新接到 viewModel.lastRefreshAt 上,这样所有 refresh 路径——
    /// 包括 SwiftUI 弹层里的 🔄 按钮——都会同步菜单栏,不需要每个 caller 自己记得调。
    private func installTitleSubscription() {
        titleSubscription = viewModel.$lastRefreshAt
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenuBarTitle() }
    }

    /// 监听偏好设置变化(provider/family 勾选状态),立即刷新菜单栏 title
    /// (合计值会因隐藏行而变;不需要重新 fetch,纯走缓存)
    private func installSettingsSubscription() {
        settingsSubscription = ProviderVisibilitySettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenuBarTitle() }
    }

    // MARK: - StatusItem

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "usageBar")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.title = " 加载中..."
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        button.target = self
    }

    func updateMenuBarTitle() {
        guard let button = statusItem.button else { return }
        let total = viewModel.visibleGrandTotalToken
        button.title = " " + formatTokens(total) + " token"
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    // MARK: - Popover

    private func configurePopover() {
        let root = UsageRootView(viewModel: viewModel)
        popover.contentSize = NSSize(width: 440, height: 260)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: root)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            guard let button = statusItem.button else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            startOutsideClickMonitor()
            // 不自动 refresh，纯走缓存（数据靠 10min 后台 + 手动 [🔄]）
        }
    }

    // MARK: - 右键菜单

    private func configureRightClickMenu() {
        rightClickMenu = NSMenu()
        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshAction), keyEquivalent: "r")
        rightClickMenu.addItem(refresh)
        rightClickMenu.addItem(NSMenuItem.separator())
        let prefs = NSMenuItem(title: "偏好设置…", action: #selector(openPreferencesAction), keyEquivalent: ",")
        rightClickMenu.addItem(prefs)
        rightClickMenu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitAction), keyEquivalent: "q")
        rightClickMenu.addItem(quit)
        rightClickMenu.items.forEach { $0.target = self }
    }

    private func installRightClickMonitor() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self,
                  let button = self.statusItem.button,
                  event.window == button.window
            else { return event }
            self.statusItem.menu = self.rightClickMenu
            button.performClick(nil)
            self.statusItem.menu = nil
            return nil
        }
    }

    // MARK: - 10 分钟定时

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.viewModel.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - 外部点击关闭

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.popover.performClose(nil)
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.stopOutsideClickMonitor()
        }
    }

    // MARK: - Actions

    @objc private func refreshAction() {
        Task {
            await viewModel.refresh()
        }
    }

    @objc private func openPreferencesAction() {
        SettingsWindowController.shared.showWindow()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
