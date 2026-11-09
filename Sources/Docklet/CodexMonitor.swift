import AppKit

/// Publishes Codex's limits by re-reading the transcripts Codex writes locally.
@MainActor
final class CodexMonitor: QuotaFeed {
    let kind: FeedKind = .codex
    var onUpdate: (() -> Void)?

    /// The snapshot exactly as Codex recorded it.
    private(set) var recordedUsage: CodexUsage?
    /// What the limits are now, after any resets since the snapshot.
    var usage: CodexUsage? { recordedUsage?.current(at: Date()) }
    private(set) var error: CodexError?
    private(set) var lastChecked: Date?

    private var timer: Timer?

    /// Transcripts only change when Codex runs, so polling can be lazy.
    var refreshInterval: TimeInterval = 30

    func start() {
        refresh()
        timer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        // Scanning transcripts touches the filesystem, so keep it off the main thread.
        Task.detached(priority: .utility) {
            let result = Result { try CodexUsageReader.latest() }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let usage):
                    self.recordedUsage = usage
                    self.error = nil
                case .failure(let failure):
                    self.error = (failure as? CodexError) ?? .noUsageRecorded
                }
                self.lastChecked = Date()
                self.onUpdate?()
            }
        }
    }

    // MARK: - Presentation

    var widgetState: WidgetState {
        if let error, usage == nil {
            return WidgetState(
                usedPercentText: "!",
                remainingPercentText: "!",
                remainingCountText: "!",
                caption: kind.displayName,
                usedFraction: 0,
                tint: .systemOrange,
                tooltip: error.errorDescription ?? "错误",
                isLoading: false,
                isError: true
            )
        }

        guard let usage, let window = usage.headline else {
            return WidgetState(
                usedPercentText: "",
                remainingPercentText: "",
                remainingCountText: "",
                caption: kind.displayName,
                usedFraction: 0,
                tint: .secondaryLabelColor,
                tooltip: "正在读取 Codex 用量",
                isLoading: true,
                isError: false
            )
        }

        let used = window.usedFraction
        let remaining = 1 - used
        let tint: NSColor
        switch remaining {
        case ..<0.1: tint = .systemRed
        case ..<0.25: tint = .systemOrange
        default: tint = .systemGreen
        }

        var tooltip = ["Codex\(usage.planType.map { " · \($0.capitalized)" } ?? "")"]
        tooltip.append("\(window.windowName)：已用 \(Int(window.usedPercent.rounded()))%\(window.hasRolledOver ? "（已重置）" : "")")
        if let resets = window.resetsAt { tooltip.append("重置于 \(Self.dateText(resets))") }
        if window.hasRolledOver {
            tooltip.append("额度已按周期重置，下次使用 Codex 后刷新实际用量")
        } else {
            tooltip.append("数据来自上次使用 Codex 时（\(Self.relativeText(usage.capturedAt))）")
        }

        return WidgetState(
            usedPercentText: "\(Int(window.usedPercent.rounded()))",
            remainingPercentText: "\(Int((remaining * 100).rounded()))",
            remainingCountText: "\(Int((remaining * 100).rounded()))",
            caption: kind.displayName,
            usedFraction: used,
            tint: tint,
            tooltip: tooltip.joined(separator: "\n"),
            isLoading: false,
            isError: false
        )
    }

    var detailSection: DetailSection {
        var rows: [DetailRow] = []
        for window in usage?.windows ?? [] {
            let remaining = 1 - window.usedFraction
            let tint: NSColor
            switch remaining {
            case ..<0.1: tint = .systemRed
            case ..<0.25: tint = .systemOrange
            default: tint = .controlAccentColor
            }
            var detail: String?
            if let resets = window.resetsAt {
                detail = window.hasRolledOver
                    ? "已重置 · 下次 \(Self.dateText(resets)) · 使用 Codex 后刷新"
                    : "\(Self.dateText(resets)) 重置"
            }
            rows.append(DetailRow(
                name: window.windowName,
                value: "已用 \(Int(window.usedPercent.rounded()))%",
                detail: detail,
                fraction: window.usedFraction,
                tint: tint
            ))
        }

        return DetailSection(
            title: "Codex",
            subtitle: usage?.planType.map { $0.capitalized } ?? "OpenAI",
            rows: rows,
            footer: lastChecked.map { "检查于 \(Formatters.time($0))" } ?? "尚未检查",
            accessory: usage.map { Self.relativeText($0.capturedAt) },
            warning: error?.errorDescription
        )
    }

    var statusLine: String {
        if let error, usage == nil { return error.errorDescription ?? "错误" }
        guard let window = usage?.headline else { return "读取中…" }
        return "Codex \(window.windowName) 已用 \(Int(window.usedPercent.rounded()))%"
    }

    var menuBarText: String? {
        usage?.headline.map { "\(Int($0.usedPercent.rounded()))%" }
    }

    // MARK: - Formatting

    private static func dateText(_ date: Date) -> String { Formatters.dateTime(date) }

    /// Makes the staleness of transcript-sourced numbers obvious rather than implied.
    private static func relativeText(_ date: Date) -> String { Formatters.relative(date) }
}
