import AppKit
import ApplicationServices

/// Follows Docklet's spacer tiles inside the Dock.
///
/// Walking the Dock's whole accessibility tree costs roughly three cross-process calls per tile,
/// which is far too expensive to repeat every frame. The Dock also animates tile geometry while
/// magnification is on, so the widget has to track at display rate or it visibly lags its
/// neighbours. This tracker therefore does the expensive discovery rarely and caches the spacer
/// element references, so a per-frame update is just two cheap position/size reads.
@MainActor
final class DockSlotTracker {
    private var listElement: AXUIElement?
    private var spacerElements: [AXUIElement] = []
    private var lastDiscovery: CFTimeInterval = 0
    private var cachedEdge: DockFrame.Edge = .bottom
    private var cachedScreen: NSScreen?

    /// How long cached tile references are trusted before rediscovering them.
    private let rediscoveryInterval: CFTimeInterval = 2.0

    /// Fewer spacers than this is assumed to be a divider the user added themselves.
    private let minimumTiles = 2

    /// Current slot geometry, rediscovering the Dock tree only when the cache is stale or invalid.
    ///
    /// `allowRediscovery` is turned off while the widget is tracking the Dock's magnify animation:
    /// a full tree walk costs three cross-process calls per tile and would land as a visible hitch
    /// in the middle of the animation.
    func currentSlot(allowRediscovery: Bool = true) -> DockSlot? {
        guard AXIsProcessTrusted() else {
            invalidate()
            return nil
        }

        let now = CACurrentMediaTime()
        let isStale = spacerElements.isEmpty || now - lastDiscovery > rediscoveryInterval
        if isStale {
            guard allowRediscovery || spacerElements.isEmpty else { return cheapSlot() }
            discover()
            lastDiscovery = now
        }

        return cheapSlot()
    }

    /// Reads only the cached spacer elements — two calls per tile, safe to run every frame.
    private func cheapSlot() -> DockSlot? {
        guard !spacerElements.isEmpty, let screen = cachedScreen else { return nil }

        var union: CGRect?
        var tileSize = CGSize.zero
        for element in spacerElements {
            guard let rect = Self.frame(of: element) else {
                // The Dock was rebuilt underneath us; drop the cache and try again next tick.
                invalidate()
                return nil
            }
            if tileSize == .zero { tileSize = rect.size }
            union = union.map { $0.union(rect) } ?? rect
        }
        guard let union, let appKit = Self.convertToAppKit(union) else { return nil }

        return DockSlot(
            rect: appKit,
            edge: cachedEdge,
            screen: screen,
            tileCount: spacerElements.count,
            tileSize: tileSize
        )
    }

    func invalidate() {
        listElement = nil
        spacerElements = []
        lastDiscovery = 0
    }

    // MARK: - Discovery

    private func discover() {
        invalidate()
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }

        let app = AXUIElementCreateApplication(dock.processIdentifier)
        guard let topLevel = Self.children(of: app) else { return }

        for candidate in topLevel {
            guard Self.stringAttribute(candidate, kAXRoleAttribute as CFString) == kAXListRole as String,
                  let listRect = Self.frame(of: candidate), listRect.width > 1, listRect.height > 1,
                  let listAppKit = Self.convertToAppKit(listRect),
                  let screen = NSScreen.screens.first(where: { $0.frame.intersects(listAppKit) }) ?? NSScreen.main,
                  let tiles = Self.children(of: candidate)
            else { continue }

            var runs: [[AXUIElement]] = []
            var run: [AXUIElement] = []
            for tile in tiles {
                if Self.stringAttribute(tile, kAXSubroleAttribute as CFString) == "AXSpacerDockItem" {
                    run.append(tile)
                } else {
                    if !run.isEmpty { runs.append(run) }
                    run = []
                }
            }
            if !run.isEmpty { runs.append(run) }

            guard let best = runs.filter({ $0.count >= minimumTiles }).max(by: { $0.count < $1.count })
            else { continue }

            listElement = candidate
            spacerElements = best
            cachedScreen = screen
            cachedEdge = listRect.width >= listRect.height
                ? .bottom
                : (listAppKit.minX <= screen.frame.midX ? .left : .right)
            return
        }
    }

    // MARK: - AX helpers

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? [AXUIElement]
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }

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
        return CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
