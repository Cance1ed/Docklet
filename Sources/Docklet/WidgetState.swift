import AppKit

/// Everything the tile needs to draw one frame, derived from the monitor on the main actor.
///
/// Quantities are framed as **used**, matching how GitHub's own Copilot UI reports them
/// ("70% used"), so the two never appear to disagree.
struct WidgetState {
    var usedPercentText: String
    var remainingPercentText: String
    var remainingCountText: String
    var caption: String
    /// Share of the allowance consumed, 0...1 — what the ring and bar fill up to.
    var usedFraction: Double
    var tint: NSColor
    var tooltip: String
    var isLoading: Bool
    var isError: Bool

    static let placeholder = WidgetState(
        usedPercentText: "",
        remainingPercentText: "",
        remainingCountText: "",
        caption: "Copilot",
        usedFraction: 0,
        tint: .secondaryLabelColor,
        tooltip: "正在读取 Copilot 额度",
        isLoading: true,
        isError: false
    )

    @MainActor
    static func make(from monitor: QuotaMonitor) -> WidgetState {
        if let error = monitor.error, monitor.quota == nil {
            return WidgetState(
                usedPercentText: "!",
                remainingPercentText: "!",
                remainingCountText: "!",
                caption: "错误",
                usedFraction: 0,
                tint: .systemOrange,
                tooltip: error.errorDescription ?? "错误",
                isLoading: false,
                isError: true
            )
        }

        guard let quota = monitor.quota, let snapshot = quota.primary else { return .placeholder }

        let remainingFraction = snapshot.unlimited ? 1 : max(0, min(1, snapshot.percentRemaining / 100))
        let usedFraction = snapshot.unlimited ? 0 : 1 - remainingFraction

        // Semantic colour tracks what is left, not what is spent: green simply means "no problem".
        let tint: NSColor
        switch remainingFraction {
        case ..<0.1: tint = .systemRed
        case ..<0.25: tint = .systemOrange
        default: tint = .systemGreen
        }

        var tooltipLines = ["\(quota.login) · \(quota.plan.capitalized)"]
        if snapshot.unlimited {
            tooltipLines.append("\(snapshot.displayName)：无限制")
        } else {
            tooltipLines.append("\(snapshot.displayName)：已用 \(Formatters.number(snapshot.used)) / \(Formatters.number(snapshot.entitlement))")
            tooltipLines.append("剩余 \(Formatters.number(snapshot.remaining))")
        }
        if let reset = quota.resetDateDisplay { tooltipLines.append("重置于 \(reset)") }

        return WidgetState(
            usedPercentText: snapshot.unlimited ? "∞" : "\(Int((usedFraction * 100).rounded()))",
            remainingPercentText: snapshot.unlimited ? "∞" : "\(Int(snapshot.percentRemaining.rounded()))",
            remainingCountText: snapshot.unlimited ? "∞" : Formatters.compact(snapshot.remaining),
            caption: "Copilot",
            usedFraction: snapshot.unlimited ? 0 : usedFraction,
            tint: tint,
            tooltip: tooltipLines.joined(separator: "\n"),
            isLoading: false,
            isError: false
        )
    }
}

/// Formatters are expensive to build, and these run on every poll and every popover reload, so
/// each one is created once and reused. All of them are thread-safe for formatting and parsing.
enum Formatters {
    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let shortDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let mediumDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func number(_ value: Double) -> String {
        decimal.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value))"
    }

    static func compact(_ value: Double) -> String {
        if value >= 10_000 { return String(format: "%.1fk", value / 1000) }
        return number(value)
    }

    static func time(_ date: Date) -> String { clock.string(from: date) }

    static func dateTime(_ date: Date) -> String { shortDateTime.string(from: date) }

    static func mediumDay(_ date: Date) -> String { mediumDate.string(from: date) }

    static func parseDay(_ string: String) -> Date? { isoDay.date(from: string) }

    static func relative(_ date: Date) -> String {
        relative.localizedString(for: date, relativeTo: Date())
    }

    static func parseISO8601(_ string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}
