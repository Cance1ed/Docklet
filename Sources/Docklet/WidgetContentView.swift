import AppKit

/// Draws the quota readout directly onto the Dock's material.
///
/// The composition adapts to the shape of the hole it lives in, because one layout cannot be
/// well-proportioned in all of them — a lone ring floating in a tall two-tile slot reads as empty
/// space, and a stacked column crammed into a single tile reads as clutter:
///
/// - **square** (one Dock tile) — a ring with the value inside it, like an Activity ring.
/// - **tall** (a stacked slot) — the value as the hero, a slim bar under it, then a caption.
/// - **wide** (a horizontal Dock) — ring on the left, value and caption stacked to its right.
///
/// In `.embedded` mode nothing is painted behind the content, so the Dock's own material shows
/// through and the widget reads as a native tile rather than a floating island.
final class WidgetContentView: NSView {
    enum Style { case embedded, floating }
    private enum Composition { case stacked, wide }

    /// What the number says. The ring already encodes proportion, so the percent forms drop the
    /// `%` sign to keep the glyph count low at tile size.
    ///
    /// `usedPercent` is the default because GitHub's own Copilot UI reports "70% used" — showing
    /// the remaining share instead made the tile look like it disagreed with the website.
    enum Readout: String, CaseIterable {
        case usedPercent
        case remainingPercent
        case remainingCount

        var menuTitle: String {
            switch self {
            case .usedPercent: return "已用百分比"
            case .remainingPercent: return "剩余百分比"
            case .remainingCount: return "剩余数量"
            }
        }
    }

    var onClick: (() -> Void)?
    var onSecondaryClick: (() -> Void)?
    /// Fired the instant a press starts, before any other work.
    var onPressBegan: (() -> Void)?

    var readout: Readout = .usedPercent {
        didSet {
            guard oldValue != readout else { return }
            if reduceMotion {
                progress.set(fillFraction)
            } else {
                progress.target = fillFraction
                startAnimating()
            }
            needsDisplay = true
        }
    }

    private var state = WidgetState.placeholder
    private var style: Style = .floating
    private var composition: Composition = .stacked
    /// Size of one neighbouring Dock tile, used to match the app icons around the widget.
    private var tileSize: CGSize?

    private var progress = Spring(value: 0, response: 0.5, dampingRatio: 1.0)
    // Critically damped: a tap carries no momentum, so overshoot here would read as a wobble.
    private var press = Spring(value: 1, response: 0.22, dampingRatio: 1.0)
    /// 0 at rest, 1 under the pointer — brightens the arc's glow so the tile feels alive.
    private var hover = Spring(value: 0, response: 0.3, dampingRatio: 1.0)

    /// How far the tile shrinks under the pointer.
    ///
    /// Deliberately tiny. A Dock tile is only about 33pt across, so the 10% dip this started with
    /// moved the artwork more than 3pt — at that scale it stops reading as a button being pressed
    /// and starts reading as the widget jumping.
    private static let pressedScale = 0.965
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0

    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false
    private var isPressedInside = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        // The artwork is laid out from the view's bounds, so a resize must repaint it. Otherwise
        // the previous bitmap is shown in the new frame and the rings appear shifted until some
        // later repaint happens to catch up.
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { displayLink?.invalidate() }

    // MARK: - Content

    func update(with newState: WidgetState) {
        let isFirstValue = state.isLoading && !newState.isLoading
        state = newState
        toolTip = newState.tooltip

        if isFirstValue || reduceMotion {
            progress.set(fillFraction)
        } else {
            progress.target = fillFraction
            startAnimating()
        }
        needsDisplay = true
    }

    /// Adopts a presentation style, the size of the space to fill, and — when embedded — the size
    /// of a neighbouring Dock tile so the artwork can match the app icons beside it.
    func configure(style: Style, size: CGSize, tileSize: CGSize? = nil) {
        // Anything but a distinctly wide box gets the stacked ring-over-caption layout. Choosing
        // between three layouts by aspect ratio meant a Dock tile — which is very nearly square —
        // flipped between showing the caption and hiding it as magnification changed its height.
        let newComposition: Composition = size.width >= size.height * 1.4 ? .wide : .stacked

        let tileChanged = tileSize.map { abs(($0.width + $0.height) - ((self.tileSize?.width ?? 0) + (self.tileSize?.height ?? 0))) > 0.5 } ?? false
        self.tileSize = tileSize

        guard newComposition != composition || style != self.style || tileChanged else { return }
        self.style = style
        composition = newComposition
        needsDisplay = true
    }

    /// Diameter that makes the ring read as the same size as the app icons next to it.
    ///
    /// A Dock tile's bounding box is noticeably larger than the icon it contains — on a 36pt Dock
    /// the tile measures about 50×38 — so filling the slot produced a circle a full size bigger
    /// than its neighbours. Deriving the diameter from the tile's short edge tracks the Dock size
    /// slider and magnification automatically.
    private func iconDiameter(fallbackWidthRatio: CGFloat) -> CGFloat {
        guard let tileSize, tileSize.width > 1, tileSize.height > 1 else {
            return bounds.width * fallbackWidthRatio
        }
        return min(tileSize.width, tileSize.height) * iconToTileRatio
    }

    /// Apple leaves a little air around a Dock icon inside its tile; this matches that inset.
    private let iconToTileRatio: CGFloat = 0.92

    /// Width the floating capsule needs; the embedded tile is sized by the Dock hole.
    var desiredWidth: CGFloat {
        guard style == .floating else { return bounds.width }
        let value = attributed(valueText, font: valueFont(for: bounds.height * 0.31))
        let caption = attributed(state.caption, font: captionFont(for: bounds.height * 0.19), secondary: true)
        return bounds.height * 0.52 + 14 + max(value.size().width, caption.size().width) + 30
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 4, bounds.height > 4 else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        defer { context.restoreGState() }

        // Press feedback scales the whole tile about its centre, like a physical key.
        let scale = press.value
        if abs(scale - 1) > 0.0001 {
            context.translateBy(x: bounds.midX, y: bounds.midY)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.midX, y: -bounds.midY)
        }

        if style == .floating { drawFloatingBackground() }

        switch composition {
        case .stacked: drawStacked()
        case .wide: drawWide()
        }
    }

    private func drawFloatingBackground() {
        let radius = bounds.height * 0.3
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.windowBackgroundColor.withAlphaComponent(0.82).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(isHovered ? 0.22 : 0.12).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// An arch with the value inside it and the product name tucked into its opening, together
    /// occupying exactly the footprint of a neighbouring app icon.
    ///
    /// A Dock tile is taller than the icon it holds — the remainder is the Dock's own padding and
    /// running-indicator strip — so sizing this group to the tile made it stand a head taller than
    /// every icon around it.
    private func drawStacked() {
        let tile = CGSize(
            width: min(tileSize?.width ?? bounds.width, bounds.width),
            height: min(tileSize?.height ?? bounds.height, bounds.height)
        )
        let iconBox = min(tile.width, tile.height) * iconToTileRatio
        guard iconBox > 10 else { return }

        // Tile centre, so the group lines up with the icons on either side.
        let centreY = bounds.maxY - tile.height / 2

        let caption = fittedCaption(maxWidth: tile.width, size: iconBox * 0.24)
        let captionHeight = state.caption.isEmpty ? 0 : caption.size().height

        // The caption overlaps the arch's opening, so the group's height is the arch's top down to
        // the caption's baseline rather than diameter plus caption. Solving that for the radius is
        // what buys back the size a closed ring had to give up to make room for the text.
        let radius = max(4, (iconBox - captionHeight) / (1 + Self.archOpeningDepth))
        let diameter = min(radius * 2, tile.width * iconToTileRatio)
        let ringCentreY = bounds.maxY - tile.height / 2 + (iconBox / 2 - diameter / 2)

        let ringRect = NSRect(
            x: bounds.midX - diameter / 2,
            y: ringCentreY - diameter / 2,
            width: diameter,
            height: diameter
        )
        drawRing(in: ringRect)
        drawCentredValue(in: ringRect, maxWidth: ringRect.width * valueWidthRatio)

        if captionHeight > 0 {
            // Sits just below the arch's open ends, inside the wedge that was cut away.
            let top = ringRect.midY - (diameter / 2) * Self.archOpeningDepth
            caption.draw(at: NSPoint(
                x: bounds.midX - caption.size().width / 2,
                y: max(centreY - iconBox / 2, top - captionHeight)
            ))
        }
    }

    /// Shrinks the product name until it clears the tile's width.
    private func fittedCaption(maxWidth: CGFloat, size: CGFloat) -> NSAttributedString {
        var pointSize = size
        var text = attributed(state.caption, font: captionFont(for: pointSize), secondary: true)
        while pointSize > 6, text.size().width > maxWidth {
            pointSize -= 0.5
            text = attributed(state.caption, font: captionFont(for: pointSize), secondary: true)
        }
        return text
    }

    private func drawWide() {
        let diameter = min(iconDiameter(fallbackWidthRatio: 0.40), bounds.height * 0.72)
        let inset = (bounds.height - diameter) / 2
        let ringRect = NSRect(x: max(4, bounds.height * 0.14), y: inset, width: diameter, height: diameter)
        drawRing(in: ringRect)
        drawCentredValue(in: ringRect, maxWidth: ringRect.width * valueWidthRatio)

        let value = attributed(valueText, font: valueFont(for: bounds.height * 0.31))
        let caption = attributed(state.caption, font: captionFont(for: bounds.height * 0.19), secondary: true)
        let x = ringRect.maxX + bounds.height * 0.22
        let spacing: CGFloat = 1
        let total = value.size().height + caption.size().height + spacing
        let bottom = bounds.midY - total / 2

        caption.draw(at: NSPoint(x: x, y: bottom))
        value.draw(at: NSPoint(x: x, y: bottom + caption.size().height + spacing))
    }

    // MARK: - Primitives

    /// Draws the gauge as an arch: a ring with a wedge removed at the bottom.
    ///
    /// The opening faces the caption, which both stops the stroke from crowding the text and lets
    /// the caption sit *inside* the gap — so the arch can be drawn noticeably larger than a closed
    /// ring would fit in the same icon-sized footprint.
    ///
    /// The fill runs from the left end of the arch to the right end, matching the reading order of
    /// a horizontal Dock; on a vertical Dock the same path reads top-to-bottom down the far side.
    private func drawRing(in rect: NSRect) {
        let lineWidth = max(2.5, rect.width * 0.12)
        let radius = (rect.width - lineWidth) / 2
        guard radius > 1 else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)

        let track = NSBezierPath()
        track.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: Self.archStartAngle,
            endAngle: Self.archStartAngle - Self.archSweepDegrees,
            clockwise: true
        )
        track.lineWidth = lineWidth
        track.lineCapStyle = .round
        trackColor.setStroke()
        track.stroke()

        guard sweep > 0.001, let context = NSGraphicsContext.current?.cgContext else { return }

        let endAngle = Self.archStartAngle - Self.archSweepDegrees * sweep
        let arc = CGMutablePath()
        arc.addArc(
            center: center,
            radius: radius,
            startAngle: Self.archStartAngle * .pi / 180,
            endAngle: endAngle * .pi / 180,
            clockwise: true
        )

        let base = (state.tint.usingColorSpace(.sRGB) ?? state.tint)
        let light = base.blended(withFraction: 0.45, of: .white) ?? base
        let glowStrength = state.isLoading || state.isError ? 0 : 0.45 + 0.4 * hover.value

        // 1. A soft halo in the tint colour, so the arc reads as lit rather than printed. It is
        //    drawn with a plain stroke because shadows do not survive the gradient's clip below.
        if glowStrength > 0 {
            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: lineWidth * (1.1 + 0.9 * hover.value),
                color: base.withAlphaComponent(glowStrength).cgColor
            )
            context.addPath(arc)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setStrokeColor(base.cgColor)
            context.strokePath()
            context.restoreGState()
        }

        // 2. The arc itself: a gradient from a lifted tint at its start to full tint at its tip,
        //    which gives the fill a sense of direction.
        context.saveGState()
        context.addPath(arc)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.replacePathWithStrokedPath()
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [light.cgColor, base.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()

        // 3. A specular bead at the tip marks exactly where the value lands.
        guard !state.isLoading, sweep > 0.04 else { return }
        let tipAngle = endAngle * .pi / 180
        let tip = CGPoint(x: center.x + cos(tipAngle) * radius, y: center.y + sin(tipAngle) * radius)
        let beadRadius = lineWidth * 0.24
        context.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.fillEllipse(in: CGRect(
            x: tip.x - beadRadius,
            y: tip.y - beadRadius,
            width: beadRadius * 2,
            height: beadRadius * 2
        ))
    }

    /// How much of a full circle the arch spans; the remainder is the opening at the bottom.
    private static let archSweepDegrees: CGFloat = 240

    /// Bottom-left end of the arch, in AppKit's counter-clockwise degrees. Derived from the sweep
    /// so the opening stays centred on the bottom however wide it is made.
    private static var archStartAngle: CGFloat { 90 + archSweepDegrees / 2 }

    /// Vertical drop from the arch's centre to its open ends, as a share of the radius. Kept in
    /// step with the sweep so the caption always tucks exactly into the opening.
    private static var archOpeningDepth: CGFloat {
        abs(sin(archStartAngle * .pi / 180))
    }

    private func drawBar(in rect: NSRect) {
        let radius = rect.height / 2
        trackColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let width = max(rect.height, rect.width * CGFloat(sweep))
        state.tint.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
            xRadius: radius,
            yRadius: radius
        ).fill()
    }

    private func drawCentredValue(in rect: NSRect, maxWidth: CGFloat) {
        let text = fittedValue(maxWidth: maxWidth, startingAt: rect.width * 0.46)
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private var sweep: Double {
        state.isLoading ? 0.16 : max(0.012, min(1, progress.value))
    }

    /// Stronger than a normal separator because this sits over translucent Dock material.
    private var trackColor: NSColor {
        NSColor.labelColor.withAlphaComponent(0.22)
    }

    // MARK: - Typography

    /// Sizes the value so that the *widest* readout this tile can ever show still fits.
    ///
    /// Fitting the current string instead made "100" render a step smaller — and therefore
    /// visibly thinner — than "85" on the tile beside it. Measuring against a fixed reference
    /// keeps every tile optically identical no matter what number it happens to be showing.
    private func fittedValue(maxWidth: CGFloat, startingAt startSize: CGFloat) -> NSAttributedString {
        // The fit depends only on geometry, so it is solved once per size rather than re-measured
        // on every animation frame.
        let key = CGSize(width: (maxWidth * 2).rounded(), height: (startSize * 2).rounded())
        let size: CGFloat
        if let cached = fittedValueSize, cached.key == key {
            size = cached.size
        } else {
            var candidate = startSize
            while candidate > 7 {
                let reference = attributed(Self.widestReadout, font: valueFont(for: candidate)).size().width
                if reference <= maxWidth { break }
                candidate -= 0.5
            }
            fittedValueSize = (key, candidate)
            size = candidate
        }
        return attributed(valueText, font: valueFont(for: size))
    }

    private var fittedValueSize: (key: CGSize, size: CGFloat)?
    private var fontCache: [CGFloat: NSFont] = [:]

    /// Widest string any readout mode produces: three digits.
    private static let widestReadout = "100"

    /// Share of the ring's diameter the number may occupy. The stroke is thin, so letting the
    /// digits run close to it keeps them at a legible size instead of shrinking a step for "100".
    private let valueWidthRatio: CGFloat = 0.80

    /// SF Rounded reads as numeric and ambient rather than textual, matching Dock iconography.
    private func valueFont(for size: CGFloat) -> NSFont {
        let pointSize = max(7, size)
        if let cached = fontCache[pointSize] { return cached }
        let base = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: pointSize) } ?? base
        if fontCache.count > 64 { fontCache.removeAll() }
        fontCache[pointSize] = font
        return font
    }

    private func captionFont(for size: CGFloat) -> NSFont {
        .systemFont(ofSize: max(6, size), weight: .medium)
    }

    private func attributed(_ string: String, font: NSFont, secondary: Bool = false) -> NSAttributedString {
        // Tracking is size-specific: large numerals read too loose, small captions too tight.
        let kern = font.pointSize >= 15 ? -font.pointSize * 0.022 : font.pointSize * 0.012

        // The Dock's material varies with whatever is behind it, so a soft shadow keeps light text
        // legible even when the wallpaper underneath happens to be bright.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = max(1.5, font.pointSize * 0.14)
        shadow.shadowOffset = CGSize(width: 0, height: -0.5)

        return NSAttributedString(string: string, attributes: [
            .font: font,
            // Hierarchy comes from size and weight rather than colour: over the Dock's varying
            // material a dimmed grey caption loses legibility long before a smaller one does.
            .foregroundColor: secondary ? primaryTextColor.withAlphaComponent(0.92) : primaryTextColor,
            .kern: kern,
            .shadow: shadow
        ])
    }

    private var valueText: String {
        guard !state.isLoading else { return "" }
        let settled: String
        switch readout {
        case .usedPercent: settled = state.usedPercentText
        case .remainingPercent: settled = state.remainingPercentText
        case .remainingCount: return state.remainingCountText
        }
        // While the arc is moving, the number counts along with it, so the two arrive together.
        // Symbols ("∞", "!", "–") are left alone.
        guard !progress.isAtRest, Int(settled) != nil else { return settled }
        return "\(Int((max(0, min(1, progress.value)) * 100).rounded()))"
    }

    /// The ring fills in the same direction the number counts, so they never contradict.
    private var fillFraction: Double {
        readout == .usedPercent ? state.usedFraction : 1 - state.usedFraction
    }

    /// Over translucent Dock material flat grey loses legibility, so the value stays full contrast.
    private var primaryTextColor: NSColor {
        state.isError ? state.tint : .labelColor
    }

    // MARK: - Animation

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func startAnimating() {
        guard displayLink == nil else { return }
        lastFrameTime = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step() {
        let now = CACurrentMediaTime()
        let dt = now - lastFrameTime
        lastFrameTime = now

        progress.advance(dt: dt)
        press.advance(dt: dt)
        hover.advance(dt: dt)
        needsDisplay = true

        if progress.isAtRest, press.isAtRest, hover.isAtRest {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        setHovered(false)
    }

    private func setHovered(_ hovered: Bool) {
        if reduceMotion {
            hover.set(hovered ? 1 : 0)
            needsDisplay = true
        } else {
            hover.target = hovered ? 1 : 0
            startAnimating()
        }
    }

    /// Feedback belongs on the press, not the release — waiting for mouse-up feels dead.
    ///
    /// Handled through the normal event methods rather than a nested `nextEvent` loop, which
    /// stalls the run loop and interferes with the popover's own open/close animations.
    override func mouseDown(with event: NSEvent) {
        onPressBegan?()
        isPressedInside = true
        setPressed(true)
    }

    override func mouseDragged(with event: NSEvent) {
        // Dragging off the tile cancels the click, like a real button.
        isPressedInside = bounds.insetBy(dx: -8, dy: -8).contains(convert(event.locationInWindow, from: nil))
        setPressed(isPressedInside)
    }

    override func mouseUp(with event: NSEvent) {
        setPressed(false)
        guard isPressedInside else { return }
        isPressedInside = false
        if event.modifierFlags.contains(.control) {
            onSecondaryClick?()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onPressBegan?()
        onSecondaryClick?()
    }

    private func setPressed(_ pressed: Bool) {
        let target = pressed ? Self.pressedScale : 1.0
        if reduceMotion {
            press.set(target)
            needsDisplay = true
        } else {
            press.target = target
            startAnimating()
        }
    }
}
