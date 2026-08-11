import AppKit
import Combine
import Sparkle
import SwiftUI
import usageBarCore

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate, NSMenuItemValidation {

    /// 右键菜单项动态可用性（NSMenu autoenablesItems 默认开,对 target 调用本方法）：
    /// 刷新进行中「立即刷新」置灰（0709 R4）。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(refreshAction) { return !viewModel.isRefreshing }
        return true
    }
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    let viewModel: UsageViewModel

    /// Sparkle 自动更新控制器（startingUpdater:true 即按 Info.plist 设置后台检查）
    private let updaterController: SPUStandardUpdaterController

    private var refreshTimer: Timer?
    private var clickMonitor: Any?
    private var rightClickMonitor: Any?
    private var rightClickMenu: NSMenu!
    private var titleSubscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var tabSettingsSubscription: AnyCancellable?
    private var themeSubscription: AnyCancellable?
    private var refreshIntervalSubscription: AnyCancellable?

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.viewModel = UsageViewModel()
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()

        configureStatusItem()
        configurePopover()
        configureRightClickMenu()
        installRightClickMonitor()
        installTitleSubscription()
        installSettingsSubscription()
        installTabSettingsSubscription()
        installThemeSubscription()
        installRefreshIntervalSubscription()

        Task {
            // 1. 先从磁盘读 mtime 缓存（< 100ms）
            await FileMtimeCache.shared.loadFromDisk()
            RateLimitStore.shared.loadFromDisk()   // 额度快照：启动即从磁盘恢复，弹层立刻有旧值
            // 2. 触发第一次 refresh（命中持久化缓存的话 < 1s 完成）
            await viewModel.refresh()
            startRefreshTimer()
        }
    }

    /// 把菜单栏 title 的更新接到 viewModel.$stats 上,这样所有 refresh 路径——
    /// 包括 SwiftUI 弹层里的 🔄 按钮和渐进提交的每一跳——都会同步菜单栏。
    private func installTitleSubscription() {
        // v0.3.13 撤掉 $stats 订阅是因为当年 handler 读「当前 tab」、切 tab 会让菜单栏漂移；
        // v0.3.30 渐进提交需要中间更新,恢复 $stats 订阅但 handler 恒读「今日」（B1 语义不破,
        // 切 tab 时 stats 变了也只是重读一遍今日合计,值不变）。
        // 首个 commit 前 allStats 为空 → updateMenuBarTitle 守住,维持「加载中...」不闪 0。
        titleSubscription = viewModel.$stats
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenuBarTitle() }
    }

    /// 主题变化 → 显式同步 popover 外观。
    /// NSPopover 锚在菜单栏状态项上，继承的是「菜单栏/系统」外观，**不吃 `NSApp.appearance` 的覆盖**，
    /// 所以设置窗变了、弹层不变。必须单独给 `popover.appearance` 赋值（.system → nil 跟随系统）。
    private func installThemeSubscription() {
        applyThemeToPopover()
        themeSubscription = ThemeSettings.shared.$theme
            .receive(on: RunLoop.main)
            .sink { [weak self] newTheme in
                self?.popover.appearance = newTheme.nsAppearance
            }
    }

    private func applyThemeToPopover() {
        popover.appearance = ThemeSettings.shared.theme.nsAppearance
    }

    /// tab 配置变化（周起始 / 自定义区间 / 勾选排序）→ 从内存缓存重算，即时刷新 popover。
    private func installTabSettingsSubscription() {
        tabSettingsSubscription = TabSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.viewModel.recomputeFromCache() }
            }
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
        // 首个渐进 commit 前维持「加载中...」，不闪 0（0709 §4）
        if viewModel.lastRefreshAt == nil && viewModel.stats.isEmpty { return }
        // 菜单栏固定显示「今日」，不随 popover 切 tab 漂移（v0.3.13 B1）
        let total = viewModel.visibleTotal(for: .today)
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
        popover.contentSize = NSSize(width: 440, height: 300)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: root)
        // 让 popover 尺寸始终跟 SwiftUI 内容（400×totalHeight）走：修首开时用默认 contentSize
        // 导致弹层与菜单栏间出现间隔的 bug（首开尺寸不对、之后布局过一次才正常）。
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            guard let button = statusItem.button else { return }
            // 今日仅单个可展开 provider 有用量 → 打开即进它的今日详情（锚定今日，与菜单栏数字一致）。
            // 否则维持总览列表（关闭时 popoverDidClose 已复位今日 + 退出详情，故重开会重新判定）。
            if viewModel.detailProviderId == nil, let sole = viewModel.soleTodayDetailProvider() {
                viewModel.openDetail(sole)
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            startOutsideClickMonitor()
            // 不自动 refresh token（纯走缓存，数据靠 10min 后台 + 手动 [🔄]）；
            // 但额度：用户此刻在看 → 允许碰钥匙串采一次（冷启动时被跳过的 Qoder/Claude-OAuth 在这补上）。
            RateLimitCoordinator.allowsKeychainAccess = true
            Task { await RateLimitCoordinator.refreshEnabled() }
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
        let checkUpdate = NSMenuItem(
            title: "检查更新…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: "")
        rightClickMenu.addItem(checkUpdate)
        rightClickMenu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitAction), keyEquivalent: "q")
        rightClickMenu.addItem(quit)
        rightClickMenu.items.forEach { $0.target = self }
        // "检查更新"交给 Sparkle 自己处理,覆盖上面统一设的 target
        checkUpdate.target = updaterController
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

    // MARK: - 定时刷新（间隔可在 设置→通用 里调，1–15 分钟）

    /// 用户拖滑轨改了频率 → 按新间隔重建定时器（下一次刷新从改动时刻重新起算）。
    private func installRefreshIntervalSubscription() {
        refreshIntervalSubscription = RefreshIntervalSettings.shared.$minutes
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.startRefreshTimer() }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: RefreshIntervalSettings.shared.interval, repeats: true) { [weak self] _ in
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
            // 关闭时退出详情页 + 复位到「今日」tab → 下次打开默认是列表态的今日
            //（否则再次打开停在旧详情页，且右上角 tag 与实际窗口不一致）
            self?.viewModel.closeDetail()
            self?.viewModel.changeWindow(.today)
        }
    }

    // MARK: - Actions

    @objc private func refreshAction() {
        // 防重入（0709 R4）：刷新在跑时连点「立即刷新」会让两代扫描抢 CPU、前一代白扫——越点越慢
        guard !viewModel.isRefreshing else { return }
        RateLimitCoordinator.allowsKeychainAccess = true   // 手动刷新是主动动作 → 允许采需授权的额度
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
