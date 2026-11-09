import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let copilot = QuotaMonitor()
    private let codex = CodexMonitor()
    private let claude = ClaudeMonitor()
    private var feeds: [QuotaFeed] = []
    private var panelController: PanelController!
    private var statusItem: NSStatusItem?
    private lazy var settingsController: SettingsWindowController = {
        let controller = SettingsWindowController()
        controller.onChange = { [weak self] in self?.applyMenuBarVisibility() }
        return controller
    }()
    /// Set while restarting into a new process, so the Dock gap survives the handover.
    private var isRelaunching = false

    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            Diagnostics.run()
            return
        }
        // Run by Claude Code as its status line, many times a session — must stay cheap.
        if CommandLine.arguments.contains("--claude-statusline") {
            ClaudeStatusLine.run()
            return
        }
        if CommandLine.arguments.contains("--dump-dock") {
            Diagnostics.dumpDock()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Claude usage is switched off and hidden from the menu. The code stays in place so it can
    /// be brought back by flipping this flag.
    private static let isClaudeFeatureAvailable = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        feeds = [copilot]
        // Codex only earns a tile when it is actually installed on this machine.
        if CodexUsageReader.isInstalled, UserDefaults.standard.object(forKey: "codexEnabled") as? Bool ?? true {
            feeds.append(codex)
        }
        if Self.isClaudeFeatureAvailable {
            if ClaudePaths.isClaudeInstalled, UserDefaults.standard.object(forKey: "claudeEnabled") as? Bool ?? true {
                ClaudeStatusLineInstaller.installIfPossible()
                feeds.append(claude)
            }
        } else {
            // Hand Claude Code's status line back if an earlier Docklet registered it; anyone
            // else's status line is left untouched.
            ClaudeStatusLineInstaller.uninstall()
        }

        panelController = PanelController(feeds: feeds)
        panelController.onOpenMenu = { [weak self] in
            guard let self else { return }
            self.panelController.presentMenu(self.buildMenu())
        }

        for feed in feeds {
            feed.onUpdate = { [weak self] in
                self?.panelController.render()
                self?.updateStatusItemTitle()
            }
        }

        // The gap in the Dock belongs to a running Docklet, so it is carved out on launch and
        // filled back in on quit rather than left behind as permanent holes.
        DockSpacerManager.installSlot(tileCount: DockSpacerManager.tilesPerFeed * feeds.count)

        // One extra run-loop turn lets the Dock publish its rebuilt AX tree after launchd respawns
        // it. This prevents the first panel layout from racing the new spacer tiles.
        DispatchQueue.main.async { [weak self] in
            self?.panelController.show()
            self?.feeds.forEach { $0.start() }
        }
        applyMenuBarVisibility()

        if !DockAnchor.isTrusted {
            DockAnchor.ensureTrusted(prompt: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        feeds.forEach { $0.stop() }
        panelController?.hide()
        if !isRelaunching {
            DockSpacerManager.removeSlotSynchronously()
        }
    }

    /// Opening Docklet again while it runs shows Settings — the way back in when the menu bar
    /// icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: - Menu bar control surface

    private func applyMenuBarVisibility() {
        if Settings.showInMenuBar {
            if statusItem == nil { setupStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Docklet")
        item.button?.imagePosition = .imageLeading
        item.menu = buildMenu()
        statusItem = item
        updateStatusItemTitle()
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }
        let parts = feeds.compactMap { feed in feed.menuBarText.map { "\(feed.kind.displayName.prefix(2)) \($0)" } }
        button.title = parts.isEmpty ? "" : " " + parts.joined(separator: "  ")
        statusItem?.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        for feed in feeds {
            let item = NSMenuItem(title: feed.statusLine, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(withTitle: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r").target = self

        let readoutItem = NSMenuItem(title: "显示内容", action: nil, keyEquivalent: "")
        let readoutMenu = NSMenu()
        for option in WidgetContentView.Readout.allCases {
            let item = NSMenuItem(title: option.menuTitle, action: #selector(selectReadout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = panelController.readout == option ? .on : .off
            readoutMenu.addItem(item)
        }
        readoutItem.submenu = readoutMenu
        menu.addItem(readoutItem)

        if CodexUsageReader.isInstalled {
            let codexItem = NSMenuItem(
                title: "显示 Codex 额度",
                action: #selector(toggleCodex),
                keyEquivalent: ""
            )
            codexItem.target = self
            codexItem.state = feeds.contains { $0.kind == .codex } ? .on : .off
            menu.addItem(codexItem)
        }

        if Self.isClaudeFeatureAvailable, ClaudePaths.isClaudeInstalled {
            let claudeItem = NSMenuItem(
                title: "显示 Claude 额度",
                action: #selector(toggleClaude),
                keyEquivalent: ""
            )
            claudeItem.target = self
            claudeItem.state = feeds.contains { $0.kind == .claude } ? .on : .off
            menu.addItem(claudeItem)
        }

        let accessibility = NSMenuItem(
            title: DockAnchor.isTrusted ? "辅助功能：已授权（贴合 Dock）" : "授权辅助功能以贴合 Dock…",
            action: DockAnchor.isTrusted ? nil : #selector(promptForAccessibility),
            keyEquivalent: ""
        )
        accessibility.target = self
        menu.addItem(accessibility)

        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "设置 GitHub Token…", action: #selector(editToken), keyEquivalent: "").target = self
        menu.addItem(withTitle: "打开 Copilot 设置页", action: #selector(openUsagePage), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Docklet", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    @objc private func refreshNow() {
        feeds.forEach { $0.refresh() }
        panelController.reposition()
    }

    @objc private func selectReadout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = WidgetContentView.Readout(rawValue: raw) else { return }
        panelController.readout = option
        updateStatusItemTitle()
    }

    /// Adding or removing the Codex tile changes how many Dock tiles Docklet needs, so the app
    /// restarts itself to rebuild the panel cleanly.
    @objc private func toggleCodex() {
        toggleFeed(.codex, defaultsKey: "codexEnabled")
    }

    @objc private func toggleClaude() {
        let wasEnabled = feeds.contains { $0.kind == .claude }
        guard toggleFeed(.claude, defaultsKey: "claudeEnabled") else { return }
        // Hand Claude Code's status line back when the tile goes away.
        if wasEnabled { ClaudeStatusLineInstaller.uninstall() }
        relaunch()
    }

    /// Returns true once the user confirms; Codex relaunches here, Claude after its cleanup.
    @discardableResult
    private func toggleFeed(_ kind: FeedKind, defaultsKey: String) -> Bool {
        let enabled = feeds.contains { $0.kind == kind }
        let alert = NSAlert()
        alert.messageText = enabled ? "隐藏 \(kind.displayName) 额度？" : "显示 \(kind.displayName) 额度？"
        alert.informativeText = "Dock 嵌入位需要重新创建，Dock 会重启一次。"
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        UserDefaults.standard.set(!enabled, forKey: defaultsKey)
        if kind != .claude { relaunch() }
        return true
    }

    @objc private func openSettings() {
        settingsController.present()
    }

    @objc private func promptForAccessibility() {
        DockAnchor.ensureTrusted(prompt: true)
    }

    @objc private func openUsagePage() {
        if let url = URL(string: "https://github.com/settings/copilot/features") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func editToken() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "GitHub Token"
        alert.informativeText = "留空并点击「清除」则自动从 gh CLI / 环境变量读取。Token 需具备 Copilot 访问权限。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = TokenStore.readKeychain() ?? ""
        field.placeholderString = "ghp_… / gho_…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            TokenStore.saveKeychain(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            copilot.refresh()
        case .alertSecondButtonReturn:
            TokenStore.deleteKeychain()
            copilot.refresh()
        default:
            break
        }
    }

    private func relaunch() {
        isRelaunching = true
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        // Give the Dock time to come back before the new instance looks for its slot.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            try? task.run()
        }
        NSApp.terminate(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
