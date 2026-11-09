import AppKit

/// Polls the Copilot quota endpoint and broadcasts state changes to the UI.
/// Publishes GitHub Copilot's quota from the endpoint the official editor plugins use.
@MainActor
final class QuotaMonitor: QuotaFeed {
    let kind: FeedKind = .copilot
    private(set) var quota: CopilotQuota?
    private(set) var error: QuotaError?
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var tokenSource: String?

    /// Called on the main actor after every state change.
    var onUpdate: (() -> Void)?

    /// Polling cadence in seconds. GitHub refreshes quota lazily, so sub-minute polling is wasteful.
    var refreshInterval: TimeInterval = 60 {
        didSet { if timer != nil { start() } }
    }

    private var timer: Timer?
    private let session: URLSession
    private let endpoint = URL(string: "https://api.github.com/copilot_internal/user")!

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

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
        guard !isRefreshing else { return }
        isRefreshing = true
        onUpdate?()

        Task { [weak self] in
            guard let self else { return }
            do {
                let (quota, source) = try await Self.fetch(session: self.session, endpoint: self.endpoint)
                self.quota = quota
                self.tokenSource = source
                self.error = nil
                self.lastUpdated = Date()
            } catch let error as QuotaError {
                self.error = error
                if error == .missingToken { self.tokenSource = nil }
            } catch {
                self.error = .transport(error.localizedDescription)
            }
            self.isRefreshing = false
            self.onUpdate?()
        }
    }

    private nonisolated static func fetch(
        session: URLSession,
        endpoint: URL
    ) async throws -> (CopilotQuota, String) {
        guard let resolved = TokenStore.resolve() else { throw QuotaError.missingToken }

        var request = URLRequest(url: endpoint)
        request.setValue("token \(resolved.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Docklet/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Docklet/1.0", forHTTPHeaderField: "Editor-Version")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw QuotaError.transport("无效的响应") }
        switch http.statusCode {
        case 200: break
        case 401: throw QuotaError.unauthorized
        case 403, 404: throw QuotaError.noCopilotSeat
        default: throw QuotaError.http(http.statusCode)
        }

        do {
            return (try JSONDecoder().decode(CopilotQuota.self, from: data), resolved.source)
        } catch {
            throw QuotaError.transport("解析失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - Presentation

extension QuotaMonitor {
    var widgetState: WidgetState { WidgetState.make(from: self) }

    var detailSection: DetailSection {
        var rows: [DetailRow] = []
        for snapshot in quota?.orderedSnapshots ?? [] {
            if snapshot.unlimited {
                rows.append(DetailRow(
                    name: snapshot.displayName,
                    value: "无限制",
                    detail: nil,
                    fraction: nil,
                    tint: .controlAccentColor
                ))
                continue
            }
            let remaining = max(0, min(1, snapshot.percentRemaining / 100))
            let tint: NSColor
            switch remaining {
            case ..<0.1: tint = .systemRed
            case ..<0.25: tint = .systemOrange
            default: tint = .controlAccentColor
            }
            rows.append(DetailRow(
                name: snapshot.displayName,
                value: "\(Formatters.number(snapshot.used)) / \(Formatters.number(snapshot.entitlement))",
                detail: "已用 \(Int((snapshot.usedFraction * 100).rounded()))% · 剩余 \(Formatters.number(snapshot.remaining))",
                fraction: snapshot.usedFraction,
                tint: tint
            ))
        }

        var subtitle = quota?.plan.capitalized ?? "等待数据"
        if let reset = quota?.resetDateDisplay {
            if let days = quota?.daysUntilReset, days >= 0 {
                subtitle += " · \(reset) 重置（\(days) 天后）"
            } else {
                subtitle += " · \(reset) 重置"
            }
        }

        return DetailSection(
            title: quota?.login ?? "GitHub Copilot",
            subtitle: subtitle,
            rows: rows,
            footer: lastUpdated.map { "更新于 \(Formatters.time($0))" } ?? "尚未更新",
            accessory: tokenSource,
            warning: error?.errorDescription
        )
    }

    var statusLine: String {
        if let error, quota == nil { return error.errorDescription ?? "错误" }
        guard let snapshot = quota?.primary else { return "读取中…" }
        if snapshot.unlimited { return "Copilot \(snapshot.displayName)：无限制" }
        return "Copilot \(snapshot.displayName) 已用 \(Formatters.number(snapshot.used)) / \(Formatters.number(snapshot.entitlement))"
    }

    var menuBarText: String? {
        guard let snapshot = quota?.primary, !snapshot.unlimited else { return nil }
        return "\(Int((snapshot.usedFraction * 100).rounded()))%"
    }
}
