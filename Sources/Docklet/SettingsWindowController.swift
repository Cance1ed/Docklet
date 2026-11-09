import AppKit

/// User preferences persisted in `UserDefaults`.
enum Settings {
    private static let showInMenuBarKey = "showInMenuBar"

    static var showInMenuBar: Bool {
        get { UserDefaults.standard.object(forKey: showInMenuBarKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showInMenuBarKey) }
    }
}

/// A small preferences window. Changes apply immediately, as macOS settings windows do.
@MainActor
final class SettingsWindowController: NSWindowController {
    /// Called after a setting changes so the app can apply it.
    var onChange: (() -> Void)?

    private let menuBarCheckbox = NSButton(checkboxWithTitle: "在菜单栏显示 Docklet", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Docklet 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent() {
        menuBarCheckbox.target = self
        menuBarCheckbox.action = #selector(toggleMenuBar)

        let hint = NSTextField(wrappingLabelWithString: "隐藏后，可以右键点击 Dock 中的额度环打开菜单和设置。")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [menuBarCheckbox, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            hint.widthAnchor.constraint(equalToConstant: 340)
        ])
        window?.contentView = content
    }

    func present() {
        menuBarCheckbox.state = Settings.showInMenuBar ? .on : .off
        // Docklet is an accessory app, so it must activate itself for the window to take focus.
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleMenuBar() {
        Settings.showInMenuBar = menuBarCheckbox.state == .on
        onChange?()
    }
}
