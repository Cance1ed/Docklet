import AppKit
import ApplicationServices

/// Position of the Dock tile strip on screen, used to glue the widget onto the Dock.
struct DockFrame: Equatable {
    enum Edge { case bottom, left, right }

    /// Dock strip rect in AppKit (bottom-left origin) coordinates.
    let rect: CGRect
    let edge: Edge
    let screen: NSScreen
    /// True when the Dock geometry is unknown and a synthetic strip is used instead.
    var isFallback = false
}

/// A run of adjacent spacer tiles inside the Dock that the widget draws into.
struct DockSlot: Equatable {
    /// Union of the spacer tiles, in AppKit (bottom-left origin) coordinates.
    let rect: CGRect
    let edge: DockFrame.Edge
    let screen: NSScreen
    let tileCount: Int
    /// Size of a single Dock tile, so content can be scaled to match neighbouring app icons
    /// instead of filling the whole slot. Follows the Dock size slider and magnification for free.
    let tileSize: CGSize
}

enum DockAnchor {
    /// Asks for Accessibility permission, optionally showing the system prompt.
    @discardableResult
    static func ensureTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Reads the Dock's tile strip geometry through the Accessibility API.
    /// Returns nil when permission is missing or the Dock is hidden.
    static func current() -> DockFrame? {
        guard let (_, rect) = dockList() else { return nil }
        guard let appKitRect = convertToAppKit(rect), let screen = screen(containing: appKitRect)
        else { return nil }
        return DockFrame(rect: appKitRect, edge: edge(for: rect, appKitRect: appKitRect, screen: screen), screen: screen)
    }

    /// Fallback strip used when Accessibility permission is unavailable:
    /// a fixed-height bar centered just above the bottom of the visible area.
    static func fallback(for screen: NSScreen) -> DockFrame {
        let visible = screen.visibleFrame
        let height: CGFloat = 52
        let rect = CGRect(
            x: visible.midX - 90,
            y: visible.minY + 10,
            width: 180,
            height: height
        )
        return DockFrame(rect: rect, edge: .bottom, screen: screen, isFallback: true)
    }

    // MARK: - AX helpers

    /// The Dock's tile container plus its frame in Accessibility (top-left) coordinates.
    private static func dockList() -> (AXUIElement, CGRect)? {
        guard AXIsProcessTrusted() else { return nil }
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }

        let app = AXUIElementCreateApplication(dock.processIdentifier)
        guard let children = copyChildren(app) else { return nil }
        for child in children {
            guard role(of: child) == kAXListRole as String else { continue }
            guard let rect = frame(of: child), rect.width > 1, rect.height > 1 else { continue }
            return (child, rect)
        }
        return nil
    }

    private static func edge(for axRect: CGRect, appKitRect: CGRect, screen: NSScreen) -> DockFrame.Edge {
        if axRect.width >= axRect.height { return .bottom }
        return appKitRect.minX <= screen.frame.midX ? .left : .right
    }

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? [AXUIElement]
    }

    private static func role(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXRoleAttribute as CFString)
    }

    private static func subrole(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXSubroleAttribute as CFString)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Frame in Accessibility coordinates (top-left origin on the primary screen).
    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func convertToAppKit(_ rect: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let flippedY = primary.frame.maxY - rect.maxY
        return CGRect(x: rect.minX, y: flippedY, width: rect.width, height: rect.height)
    }

    private static func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
    }
}
