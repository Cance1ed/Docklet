import AppKit

/// One quota source rendered as its own Dock tile.
enum FeedKind: String, CaseIterable {
    case copilot
    case codex
    case claude

    var displayName: String {
        switch self {
        case .copilot: return "Copilot"
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}

/// A row in the detail popover.
struct DetailRow {
    var name: String
    var value: String
    var detail: String?
    /// Share consumed, 0...1. `nil` renders without a bar (an unlimited allowance).
    var fraction: Double?
    var tint: NSColor
}

/// A provider's block in the detail popover.
struct DetailSection {
    var title: String
    var subtitle: String
    var rows: [DetailRow]
    var footer: String
    var accessory: String?
    var warning: String?
}

/// Anything that can drive a tile: polls somewhere, then publishes a drawable snapshot.
@MainActor
protocol QuotaFeed: AnyObject {
    var kind: FeedKind { get }
    var onUpdate: (() -> Void)? { get set }

    var widgetState: WidgetState { get }
    var detailSection: DetailSection { get }
    /// Short summary for the menu bar and menus.
    var statusLine: String { get }
    /// Used percentage for the menu bar title, when the feed has one.
    var menuBarText: String? { get }

    func start()
    func stop()
    func refresh()
}
