import AppKit

/// Publishes Claude's plan limits from the snapshot Claude Code's status line leaves behind.
@MainActor
final class ClaudeMonitor: QuotaFeed {
    let kind: FeedKind = .claude
    var onUpdate: (() -> Void)?

    /// The snapshot exactly as Claude Code reported it.
    private(set) var recordedUsage: ClaudeUsage?
    /// What the limits are now, after any resets since the snapshot.
    var usage: ClaudeUsage? { recordedUsage?.current(at: Date()) }
    private(set) var error: ClaudeError?
    private(set) var lastChecked: Date?

    private var timer: Timer?

    /// Reading one small file is cheap, and Claude Code refreshes it on every turn.
    var refreshInterval: TimeInterval = 15

    func start() {
        refresh()
        timer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(forceLive: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Latest numbers from Anthropic, and why the last live attempt failed, if it did.
    private var liveUsage: ClaudeUsage?
    private var liveError: ClaudeError?
    private var lastLiveAttempt: Date = .distantPast
    /// The local file is re-read every poll; the network only this often.
    private let liveInterval: TimeInterval = 60

    /// A manual refresh asks Anthropic straight away rather than waiting out `liveInterval`.
    func refresh() {
        refresh(forceLive: true)
    }

    private func refresh(forceLive: Bool) {
        let fetchLive = forceLive || Date().timeIntervalSince(lastLiveAttempt) >= liveInterval
        if fetchLive { lastLiveAttempt = Date() }

        Task.detached(priority: .utility) {
            var live: Result<ClaudeUsage, Error>?
            if fetchLive {
                do { live = .success(try await ClaudeLiveUsage.fetch()) } catch { live = .failure(error) }
            }
            let snapshot = Result { try ClaudeUsageReader.latest() }

            await MainActor.run { [weak self] in
                guard let self else { return }
                switch live {
                case .success(let usage):
                    self.liveUsage = usage
                    self.liveError = nil
                case .failure(let failure):
                    let error = (failure as? ClaudeError) ?? .liveUnavailable
                    self.liveError = error
                    // A dead login means the old live numbers can no longer be refreshed; a
                    // network blip does not, and those numbers stay labelled with their age.
                    if error != .liveUnavailable { self.liveUsage = nil }
                case nil:
                    break
                }

                // Whichever source saw Claude most recently wins. A missing snapshot clears
                // nothing but itself, so stale numbers are never presented as current.
                let snapshotUsage = try? snapshot.get()
                self.recordedUsage = [self.liveUsage, snapshotUsage]
                    .compactMap { $0 }
                    .max { $0.capturedAt < $1.capturedAt }

                if self.recordedUsage == nil {
                    // Prefer the snapshot's explanation when it names a configuration problem.
                    var snapshotError = ClaudeError.noUsageRecorded
                    if case .failure(let failure as ClaudeError) = snapshot { snapshotError = failure }
                    let isConfigProblem = snapshotError == .notInstalled || snapshotError == .statusLineOccupied
                    self.error = isConfigProblem ? snapshotError : (self.liveError ?? snapshotError)
                } else {
                    // Data is on screen; only a login problem is worth a warning, since it means
                    // the numbers will stop updating.
                    self.error = self.liveError == .liveUnavailable ? nil : self.liveError
                }
                self.lastChecked = Date()
                self.onUpdate?()
            }
        }
    }

    // MARK: - Presentation

    var widgetState: WidgetState {
        guard let usage, let window = usage.headline else {
            // Not having used Claude Code yet is a normal state, not an error, so it reads as an
            // empty gauge; only a configuration problem gets the warning treatment.
            let isProblem = [.statusLineOccupied, .notInstalled, .loginExpired, .loginUnavailable].contains(error)
            let mark = isProblem ? "!" : "–"
            return WidgetState(
                usedPercentText: mark,
                remainingPercentText: mark,
                remainingCountText: mark,
                caption: kind.displayName,
                usedFraction: 0,
                tint: isProblem ? .systemOrange : .secondaryLabelColor,
                tooltip: error?.errorDescription ?? "正在读取 Claude 用量",
                isLoading: error == nil,
                isError: isProblem
            )
        }

        let used = window.usedFraction
        let remaining = 1 - used
        var tooltip = ["Claude"]
        for item in usage.windows {
            tooltip.append("\(item.windowName)：已用 \(Int(item.usedPercent.rounded()))%\(item.hasRolledOver ? "（已重置）" : "")")
        }
        if let resets = window.resetsAt { tooltip.append("重置于 \(Self.dateText(resets))") }
        tooltip.append("数据来自上次使用 Claude Code 时（\(Self.relativeText(usage.capturedAt))）")

        return WidgetState(
            usedPercentText: "\(Int(window.usedPercent.rounded()))",
            remainingPercentText: "\(Int((remaining * 100).rounded()))",
            remainingCountText: "\(Int((remaining * 100).rounded()))",
            caption: kind.displayName,
            usedFraction: used,
            tint: Self.tint(remaining: remaining, normal: .systemGreen),
            tooltip: tooltip.joined(separator: "\n"),
            isLoading: false,
            isError: false
        )
    }

    var detailSection: DetailSection {
        let rows = (usage?.windows ?? []).map { window -> DetailRow in
            var detail: String?
            if let resets = window.resetsAt {
                detail = window.hasRolledOver
                    ? "已重置 · 下次 \(Self.dateText(resets)) · 使用 Claude Code 后刷新"
                    : "\(Self.dateText(resets)) 重置"
            }
            return DetailRow(
                name: window.windowName,
                value: "已用 \(Int(window.usedPercent.rounded()))%",
                detail: detail,
                fraction: window.usedFraction,
                tint: Self.tint(remaining: 1 - window.usedFraction, normal: .controlAccentColor)
            )
        }

        return DetailSection(
            title: "Claude",
            subtitle: "Claude Code",
            rows: rows,
            footer: lastChecked.map { "检查于 \(Formatters.time($0))" } ?? "尚未检查",
            accessory: usage.map { Self.relativeText($0.capturedAt) },
            warning: error?.errorDescription
        )
    }

    var statusLine: String {
        guard let window = usage?.headline else { return error?.errorDescription ?? "读取中…" }
        return "Claude \(window.windowName) 已用 \(Int(window.usedPercent.rounded()))%"
    }

    var menuBarText: String? {
        usage?.headline.map { "\(Int($0.usedPercent.rounded()))%" }
    }

    // MARK: - Formatting

    private static func tint(remaining: Double, normal: NSColor) -> NSColor {
        switch remaining {
        case ..<0.1: return .systemRed
        case ..<0.25: return .systemOrange
        default: return normal
        }
    }

    private static func dateText(_ date: Date) -> String { Formatters.dateTime(date) }

    private static func relativeText(_ date: Date) -> String { Formatters.relative(date) }
}
