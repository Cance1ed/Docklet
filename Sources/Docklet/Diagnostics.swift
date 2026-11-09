import AppKit
import ApplicationServices

/// `Docklet --diagnose` prints why the widget may not be attaching to the Dock.
/// `Docklet --dump-dock` walks the Dock's accessibility tree, tile by tile.
enum Diagnostics {
    @MainActor
    static func run() {
        print("bundle id      :", Bundle.main.bundleIdentifier ?? "nil")
        print("bundle path    :", Bundle.main.bundlePath)
        print("AX trusted     :", DockAnchor.isTrusted)

        if let dock = DockAnchor.current() {
            print("dock rect      :", dock.rect, "edge:", dock.edge)
        } else {
            print("dock rect      : nil (无权限或未找到 Dock 列表元素)")
        }

        if let token = TokenStore.resolve() {
            print("token source   :", token.source, "len:", token.value.count)
        } else {
            print("token source   : none")
        }

        for screen in NSScreen.screens {
            print("screen         :", screen.frame, "visible:", screen.visibleFrame)
        }

        print("codex installed:", CodexUsageReader.isInstalled)
        do {
            let usage = try CodexUsageReader.latest()
            print("codex plan     :", usage.planType ?? "-")
            print("codex captured :", usage.capturedAt)
            for window in usage.current(at: Date()).windows {
                print("codex window   :", window.windowName, "used", window.usedPercent, "% resets", window.resetsAt.map(String.init(describing:)) ?? "-", window.hasRolledOver ? "(rolled over)" : "")
            }
        } catch {
            print("codex error    :", error.localizedDescription)
        }

        print("claude installed:", ClaudePaths.isClaudeInstalled, "statusline:", ClaudeStatusLineInstaller.state)
        do {
            let usage = try ClaudeUsageReader.latest()
            print("claude captured:", usage.capturedAt)
            for window in usage.current(at: Date()).windows {
                print("claude window  :", window.windowName, "used", window.usedPercent, "% resets", window.resetsAt.map(String.init(describing:)) ?? "-", window.hasRolledOver ? "(rolled over)" : "")
            }
        } catch {
            print("claude error   :", error.localizedDescription)
        }
    }

    @MainActor
    static func dumpDock() {
        guard AXIsProcessTrusted() else {
            print("需要辅助功能权限")
            return
        }
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        walk(app, depth: 0, maxDepth: 3)
    }

    private static func walk(_ element: AXUIElement, depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else { return }
        let indent = String(repeating: "  ", count: depth)

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        var point = CGPoint.zero
        var size = CGSize.zero
        if let posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &point) }
        if let sizeRef { AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) }

        let role = roleRef as? String ?? "?"
        let subrole = subroleRef as? String ?? ""
        let title = titleRef as? String ?? ""
        print("\(indent)\(role) \(subrole) '\(title)' @\(Int(point.x)),\(Int(point.y)) \(Int(size.width))x\(Int(size.height))")

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            walk(child, depth: depth + 1, maxDepth: maxDepth)
        }
    }
}
