import AppKit
import QuartzCore

/// Borderless panel that fills Docklet's hole inside the Dock.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    private let panel: WidgetPanel
    private let feeds: [QuotaFeed]
    private let stack = TileStackView(frame: NSRect(x: 0, y: 0, width: 50, height: 76))
    private var tiles: [FeedKind: WidgetContentView] = [:]
    private let popover = NSPopover()
    private let tracker = DockSlotTracker()
    private var detailController: QuotaDetailViewController?

    private var idleTimer: Timer?
    private var displayLink: CADisplayLink?
    private var isRunning = false

    /// Gap between the Dock strip and the widget when floating beside it.
    private let gap: CGFloat = 8
    /// How far from the Dock the pointer may be before frame-rate tracking switches off.
    private let trackingMargin: CGFloat = 140
    /// How long to keep tracking after the Dock's geometry last moved, so its magnify/un-magnify
    /// animation is followed all the way to rest instead of stepping at the idle timer's rate.
    private let settleDuration: CFTimeInterval = 0.9
    private var lastGeometryChange: CFTimeInterval = 0
    private var mouseMonitor: Any?
    /// Cached so the panel's appearance is only reassigned when it genuinely changes.
    private var appliedStyle: WidgetContentView.Style?

    private var dismissGlobalMonitor: Any?
    private var dismissLocalMonitor: Any?
    private var dismissObserver: NSObjectProtocol?

    var onOpenMenu: (() -> Void)?
    private(set) var isEmbedded = false
    private var lastPaintedSize: NSSize = .zero
    private var restingSlot: (rect: NSRect, tileSize: CGSize)?
    private var prediction: (start: CFTimeInterval, from: NSRect)?
    private var pointerWasInsideDock = false
    private var isMenuOpen = false
    private var maxSlotDepth: CGFloat = 0
    /// Where the embedded slot's Dock sits and on which screen, so pointer proximity can be judged
    /// against the whole Dock strip rather than just the tiles.
    private var embeddedEdge: DockFrame.Edge = .bottom
    private var embeddedScreenFrame: NSRect = .zero

    /// Persisted so the choice survives relaunches.
    var readout: WidgetContentView.Readout {
        get { tiles.values.first?.readout ?? .usedPercent }
        set {
            tiles.values.forEach { $0.readout = newValue }
            UserDefaults.standard.set(newValue.rawValue, forKey: "readout")
        }
    }

    init(feeds: [QuotaFeed]) {
        self.feeds = feeds

        panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 50, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // Sit in the Dock's own window band so the widget is occluded and revealed with it.
        // Same level as the Dock loses whenever the Dock re-orders its own window, hiding the tiles.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = stack

        let savedReadout = UserDefaults.standard.string(forKey: "readout")
            .flatMap(WidgetContentView.Readout.init(rawValue:)) ?? .usedPercent

        for feed in feeds {
            let tile = WidgetContentView(frame: .zero)
            tile.readout = savedReadout
            tile.onClick = { [weak self] in self?.toggleDetails(focusing: feed.kind) }
            tile.onSecondaryClick = { [weak self] in self?.onOpenMenu?() }
            // A press steals the pointer from the Dock, which un-magnifies in response. Following
            // that at display rate keeps the tiles aligned with their neighbours; freezing the
            // geometry instead left them offset until the freeze expired.
            tile.onPressBegan = { [weak self] in
                self?.lastGeometryChange = CACurrentMediaTime()
                self?.startDisplayLink()
            }
            tiles[feed.kind] = tile
        }

        // Dismissal is owned by the monitors below. A transient popover let AppKit close it with
        // its shrink animation on the tile click, and until that animation's window went away the
        // WindowServer held the parent panel in place — the tiles froze, then leapt once it ended.
        popover.behavior = .applicationDefined
        popover.animates = true
        // Keep the detail panel in the system appearance even though the tiles are forced dark.
        popover.appearance = NSAppearance(named: .aqua)
    }

    func show() {
        isRunning = true
        render()
        panel.orderFrontRegardless()
        startFollowing()
    }

    func hide() {
        isRunning = false
        closeDetails()
        panel.orderOut(nil)
        displayLink?.invalidate()
        displayLink = nil
        idleTimer?.invalidate()
        idleTimer = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    /// Pushes the latest feed states into the tiles and any open popover.
    func render() {
        for feed in feeds {
            tiles[feed.kind]?.update(with: feed.widgetState)
        }
        detailController?.reload()
        reposition()
    }

    /// Forces a full rediscovery — used after the Dock restarts.
    func invalidateDockCache() {
        tracker.invalidate()
        restingSlot = nil
        prediction = nil
        maxSlotDepth = 0
        reposition()
    }

    func presentMenu(_ menu: NSMenu) {
        let point = NSPoint(x: panel.frame.width / 2, y: panel.frame.height + 4)
        // The Dock stays magnified for as long as the menu is open, even with the pointer up in
        // the menu, so leaving the Dock must not be read as the Dock about to shrink back.
        isMenuOpen = true
        prediction = nil
        menu.popUp(positioning: nil, at: point, in: stack)
        isMenuOpen = false
        pointerWasInsideDock = false
        lastGeometryChange = CACurrentMediaTime()
        startDisplayLink()
    }

    // MARK: - Detail popover

    private func toggleDetails(focusing kind: FeedKind) {
        if popover.isShown {
            closeDetails()
            return
        }
        let controller = QuotaDetailViewController(feeds: feeds) { [weak self] in
            self?.closeDetails()
            self?.onOpenMenu?()
        }
        detailController = controller
        popover.contentViewController = controller

        let anchor: NSView = tiles[kind] ?? stack
        // Showing the popover loads it and reloads its content, which also starts the bars' sweep.
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: popoverEdge)
        startDisplayLink()
        startDismissMonitors()
    }

    private func closeDetails() {
        stopDismissMonitors()
        guard popover.isShown else { return }
        // Closing is instant. While the popover animates out, moves of its parent panel are not
        // presented, so the tiles froze in place as the Dock un-magnified and then leapt across
        // once the fade finished.
        popover.animates = false
        popover.close()
        popover.animates = true
    }

    private var popoverEdge: NSRectEdge {
        guard let slot = tracker.currentSlot() else { return .maxY }
        switch slot.edge {
        case .bottom: return .maxY
        case .left: return .maxX
        case .right: return .minX
        }
    }

    /// `NSPopover.transient` dismissal relies on the owning app seeing the stray click, but
    /// Docklet is an accessory app whose panel never activates it — so clicks in other apps never
    /// reach the popover. These monitors close it the way a transient popover is expected to.
    private func startDismissMonitors() {
        stopDismissMonitors()

        let clickTypes: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        dismissGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clickTypes) { [weak self] _ in
            Task { @MainActor in self?.closeDetails() }
        }

        dismissLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: clickTypes.union(.keyDown)) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                Task { @MainActor in self.closeDetails() }
                return nil
            }
            let isOwnWindow = event.window === self.popover.contentViewController?.view.window
                || event.window === self.panel
            if !isOwnWindow {
                Task { @MainActor in self.closeDetails() }
            }
            return event
        }

        dismissObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closeDetails() }
        }
    }

    private func stopDismissMonitors() {
        if let dismissGlobalMonitor { NSEvent.removeMonitor(dismissGlobalMonitor) }
        if let dismissLocalMonitor { NSEvent.removeMonitor(dismissLocalMonitor) }
        if let dismissObserver { NotificationCenter.default.removeObserver(dismissObserver) }
        dismissGlobalMonitor = nil
        dismissLocalMonitor = nil
        dismissObserver = nil
    }

    // MARK: - Following the Dock

    /// The Dock animates tile geometry while magnification is on, so the widget tracks at display
    /// rate whenever the pointer is near the Dock and drops to a lazy timer the rest of the time.
    private func startFollowing() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickIdle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer

        // Waiting for the idle timer to notice the pointer meant the first ~0.6s of the Dock's
        // magnify animation played back in steps, so arrival is detected from the event stream.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldTrackAtFrameRate else { return }
                self.startDisplayLink()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.invalidateDockCache() }
        }
    }

    private func tickIdle() {
        reposition(allowRediscovery: true)
        if shouldTrackAtFrameRate {
            startDisplayLink()
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = panel.displayLink(target: self, selector: #selector(tickFrame))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tickFrame() {
        // Never rediscover mid-animation: a full tree walk is a visible hitch.
        reposition(allowRediscovery: false)
        if !shouldTrackAtFrameRate {
            Trace.log("LINK STOP")
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// Frame-rate tracking stays on while the pointer is near the Dock *and* for a short settle
    /// window after the geometry last changed. Stopping the moment the pointer leaves made the
    /// Dock's un-magnify animation play back in visible 0.6s steps.
    private var shouldTrackAtFrameRate: Bool {
        guard isEmbedded else { return false }
        if prediction != nil { return true }
        // While the popover is open the pointer often sits away from the Dock, but the tiles must
        // still track it so opening or closing the panel never leaves them behind.
        if popover.isShown { return true }
        if CACurrentMediaTime() - lastGeometryChange < settleDuration { return true }
        return isPointerOverDockStrip
    }

    /// Magnifying icons anywhere along the Dock pushes the slot sideways even when the pointer is
    /// far from it, so proximity is judged against the whole strip. Watching only the tiles let
    /// the neighbours shift while the tiles waited for the idle timer, reading as a lurch.
    private var isPointerOverDockStrip: Bool {
        let pointer = NSEvent.mouseLocation
        guard embeddedScreenFrame.insetBy(dx: -1, dy: -1).contains(pointer) else { return false }
        switch embeddedEdge {
        case .bottom: return pointer.y <= panel.frame.maxY + trackingMargin
        case .left: return pointer.x <= panel.frame.maxX + trackingMargin
        case .right: return pointer.x >= panel.frame.minX - trackingMargin
        }
    }

    /// Snaps the panel onto the Dock's spacer slot, or beside the Dock when no slot exists.
    func reposition(allowRediscovery: Bool = true) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        if let slot = tracker.currentSlot(allowRediscovery: allowRediscovery) {
            if Trace.isEnabled { Trace.log("SLOT raw x=\(Int(slot.rect.minX)) w=\(Int(slot.rect.width)) panel x=\(Int(panel.frame.minX)) w=\(Int(panel.frame.width)) link=\(displayLink != nil) popover=\(popover.isShown)") }
            isEmbedded = true
            embeddedEdge = slot.edge
            embeddedScreenFrame = slot.screen.frame
            guard ensureVisible(dockRect: slot.rect, edge: slot.edge, screen: slot.screen) else { return }
            let target = predictedFrame(for: slot) ?? (slot.rect, slot.tileSize)
            apply(frame: target.rect, style: .embedded, edge: slot.edge, tileSize: target.tileSize)
            return
        }

        if isEmbedded { Trace.log("LOST SLOT -> floating") }
        isEmbedded = false
        let dock = DockAnchor.current() ?? DockAnchor.fallback(for: screen)

        if !dock.isFallback {
            guard ensureVisible(dockRect: dock.rect, edge: dock.edge, screen: dock.screen) else { return }
        }

        let height = dock.isFallback
            ? dock.rect.height
            : (dock.edge == .bottom ? max(34, min(88, dock.rect.height * 0.74)) : 48)
        let width = min(max(124, ceil(CGFloat(feeds.count) * height * 2.1)), 420)
        let size = CGSize(width: width, height: height)
        apply(
            frame: NSRect(origin: floatingOrigin(dock: dock, size: size), size: size),
            style: .floating,
            edge: .bottom,
            tileSize: nil
        )
    }

    private func apply(frame: NSRect, style: WidgetContentView.Style, edge: DockFrame.Edge, tileSize: CGSize?) {
        // Applied 1:1, never smoothed: the neighbouring icons move exactly with the Dock, so any
        // easing here shows up as the tiles trailing behind them and then catching up.
        let rounded = NSRect(
            x: frame.origin.x.rounded(),
            y: frame.origin.y.rounded(),
            width: frame.width.rounded(),
            height: frame.height.rounded()
        )
        // The Dock renders a dark vibrant material regardless of the system's light/dark setting,
        // so semantic colours must resolve light-on-dark or the readout turns black on black.
        // Reassigning this every frame forced an appearance change and a relayout, which showed up
        // as the tiles twitching whenever the popover opened or closed.
        if appliedStyle != style {
            appliedStyle = style
            panel.appearance = NSAppearance(named: style == .embedded ? .vibrantDark : .aqua)
        }

        let ordered = feeds.compactMap { tiles[$0.kind] }
        stack.setTiles(ordered, axis: style == .embedded ? edge : .bottom)

        if panel.frame != rounded {
            Trace.log("FRAME x \(Int(panel.frame.minX))->\(Int(rounded.minX)) w \(Int(panel.frame.width))->\(Int(rounded.width)) h \(Int(panel.frame.height))->\(Int(rounded.height)) popover=\(popover.isShown) mouse=\(Int(NSEvent.mouseLocation.x)),\(Int(NSEvent.mouseLocation.y))")
            lastGeometryChange = CACurrentMediaTime()
            panel.setFrame(rounded, display: false)
            stack.frame = NSRect(origin: .zero, size: rounded.size)
        }
        let frameChanged = panel.frame.size != lastPaintedSize
        stack.layoutSubtreeIfNeeded()

        // Configure after layout so each tile knows its own final size.
        for tile in ordered {
            tile.configure(style: style, size: tile.bounds.size, tileSize: tileSize)
            if frameChanged { tile.needsDisplay = true }
        }
        if frameChanged {
            lastPaintedSize = panel.frame.size
            // Paint in the same pass as the move so the window never shows a frame whose
            // contents were drawn for its previous size.
            panel.displayIfNeeded()
        }
    }

    // MARK: - Un-magnify prediction

    /// After a click the Dock's accessibility geometry trails what it draws by up to ~200ms, so
    /// following it alone left the tiles parked at their magnified position after the Dock had
    /// already shrunk back, then jumping. The Dock always settles at its resting layout once the
    /// pointer leaves it, so that exit is anticipated: the tiles glide to the remembered resting
    /// slot in step with the Dock and resume following the reported geometry once it agrees.
    private func predictedFrame(for slot: DockSlot) -> (rect: NSRect, tileSize: CGSize)? {
        let now = CACurrentMediaTime()
        let pointer = NSEvent.mouseLocation
        let depth = extent(of: slot.rect, along: slot.edge)
        maxSlotDepth = max(maxSlotDepth, depth)

        // Resting geometry is only trustworthy when the pointer is well clear of the Dock and
        // nothing has moved for a while — magnification anywhere along the Dock shifts the slot.
        if !isPointerOverDockStrip, now - lastGeometryChange > 0.3, prediction == nil {
            restingSlot = (slot.rect, slot.tileSize)
        }

        let outside = distanceBeyondDock(pointer, slot: slot) > 1
        defer { pointerWasInsideDock = !outside }

        if prediction == nil, !isMenuOpen, outside, pointerWasInsideDock, let rest = restingSlot,
           depth > extent(of: rest.rect, along: slot.edge) + 3 {
            prediction = (start: now, from: panel.frame)
            Trace.log("PREDICT un-magnify -> \(rest.rect)")
        }

        guard let active = prediction, let rest = restingSlot else { return nil }
        let reportedAtRest = abs(depth - extent(of: rest.rect, along: slot.edge)) < 1
        if !outside || reportedAtRest || now - active.start > 0.6 {
            prediction = nil
            return nil
        }

        // Matches the Dock's own short un-magnify, eased out so it lands softly.
        let t = min(1, (now - active.start) / 0.09)
        let eased = 1 - pow(1 - t, 3)
        let from = active.from
        let rect = NSRect(
            x: from.minX + (rest.rect.minX - from.minX) * eased,
            y: from.minY + (rest.rect.minY - from.minY) * eased,
            width: from.width + (rest.rect.width - from.width) * eased,
            height: from.height + (rest.rect.height - from.height) * eased
        )
        let scale = rect.width / max(rest.rect.width, 1)
        let tile = CGSize(width: rest.tileSize.width * scale, height: rest.tileSize.height * scale)
        return (rect, tile)
    }

    /// How far a slot reaches out from the screen edge, which is what magnification grows.
    private func extent(of rect: NSRect, along edge: DockFrame.Edge) -> CGFloat {
        edge == .bottom ? rect.height : rect.width
    }

    /// Positive once the pointer is past the outer edge of the fully magnified Dock.
    private func distanceBeyondDock(_ pointer: NSPoint, slot: DockSlot) -> CGFloat {
        switch slot.edge {
        case .bottom: return pointer.y - (slot.rect.minY + maxSlotDepth)
        case .left: return pointer.x - (slot.rect.minX + maxSlotDepth)
        case .right: return (slot.rect.maxX - maxSlotDepth) - pointer.x
        }
    }

    /// Hides the panel while the Dock is slid off-screen by auto-hide; returns false when hidden.
    private func ensureVisible(dockRect: CGRect, edge: DockFrame.Edge, screen: NSScreen) -> Bool {
        let screenFrame = screen.frame
        let visible: Bool
        switch edge {
        case .bottom: visible = dockRect.maxY > screenFrame.minY + 4
        case .left: visible = dockRect.maxX > screenFrame.minX + 4
        case .right: visible = dockRect.minX < screenFrame.maxX - 4
        }

        if !visible {
            if panel.isVisible {
                closeDetails()
                panel.orderOut(nil)
            }
            return false
        }
        if !panel.isVisible, isRunning {
            panel.orderFrontRegardless()
        }
        return true
    }

    private func floatingOrigin(dock: DockFrame, size: CGSize) -> CGPoint {
        let screenFrame = dock.screen.frame
        if dock.isFallback {
            return CGPoint(x: dock.rect.midX - size.width / 2, y: dock.rect.minY)
        }
        switch dock.edge {
        case .bottom:
            let y = dock.rect.midY - size.height / 2
            var x = dock.rect.maxX + gap
            if x + size.width > screenFrame.maxX - 6 {
                x = dock.rect.minX - gap - size.width
            }
            x = min(max(x, screenFrame.minX + 6), screenFrame.maxX - size.width - 6)
            return CGPoint(x: x, y: max(screenFrame.minY + 2, y))
        case .left:
            let x = dock.rect.maxX + gap
            let y = min(dock.rect.maxY + gap, screenFrame.maxY - size.height - 30)
            return CGPoint(x: x, y: y)
        case .right:
            let x = dock.rect.minX - gap - size.width
            let y = min(dock.rect.maxY + gap, screenFrame.maxY - size.height - 30)
            return CGPoint(x: x, y: y)
        }
    }
}
