import AppKit

/// Lays the individual feed tiles out along the Dock's axis and keeps each one square, so every
/// tile lines up with the app icons beside it instead of stretching to fill the slot.
final class TileStackView: NSView {
    private(set) var tiles: [WidgetContentView] = []
    private var axis: DockFrame.Edge = .left

    func setTiles(_ views: [WidgetContentView], axis: DockFrame.Edge) {
        guard views.map(ObjectIdentifier.init) != tiles.map(ObjectIdentifier.init) || axis != self.axis else { return }
        tiles.forEach { $0.removeFromSuperview() }
        tiles = views
        self.axis = axis
        views.forEach { addSubview($0) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !tiles.isEmpty else { return }

        switch axis {
        case .bottom:
            let width = bounds.width / CGFloat(tiles.count)
            for (index, tile) in tiles.enumerated() {
                tile.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
            }
        case .left, .right:
            // Dock tiles run top-to-bottom, and so does the reading order here.
            let height = bounds.height / CGFloat(tiles.count)
            for (index, tile) in tiles.enumerated() {
                let y = bounds.height - CGFloat(index + 1) * height
                tile.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            }
        }
    }
}
