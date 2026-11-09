import Foundation

struct QuotaSnapshot: Decodable, Hashable {
    let quotaId: String
    let percentRemaining: Double
    let unlimited: Bool
    let entitlement: Double
    let remaining: Double
    let creditsUsed: Double
    let overageCount: Double
    let overagePermitted: Bool

    enum CodingKeys: String, CodingKey {
        case quotaId = "quota_id"
        case percentRemaining = "percent_remaining"
        case unlimited
        case entitlement
        case remaining
        case creditsUsed = "credits_used"
        case overageCount = "overage_count"
        case overagePermitted = "overage_permitted"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quotaId = try c.decodeIfPresent(String.self, forKey: .quotaId) ?? "unknown"
        percentRemaining = try c.decodeIfPresent(Double.self, forKey: .percentRemaining) ?? 0
        unlimited = try c.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
        entitlement = try c.decodeIfPresent(Double.self, forKey: .entitlement) ?? 0
        remaining = try c.decodeIfPresent(Double.self, forKey: .remaining) ?? 0
        creditsUsed = try c.decodeIfPresent(Double.self, forKey: .creditsUsed) ?? 0
        overageCount = try c.decodeIfPresent(Double.self, forKey: .overageCount) ?? 0
        overagePermitted = try c.decodeIfPresent(Bool.self, forKey: .overagePermitted) ?? false
    }

    var displayName: String {
        switch quotaId {
        case "premium_interactions": return "Premium"
        case "chat": return "Chat"
        case "completions": return "Completions"
        default: return quotaId.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Allowance consumed so far. Derived rather than read from `credits_used`, which GitHub
    /// reports in raw credits and does not always line up with the entitlement scale.
    var used: Double {
        max(0, entitlement - remaining)
    }

    var usedFraction: Double {
        guard !unlimited, entitlement > 0 else { return 0 }
        return max(0, min(1, 1 - percentRemaining / 100))
    }
}

struct CopilotQuota: Decodable, Hashable {
    let login: String
    let plan: String
    let resetDate: String?
    let snapshots: [String: QuotaSnapshot]

    enum CodingKeys: String, CodingKey {
        case login
        case plan = "copilot_plan"
        case resetDate = "quota_reset_date"
        case snapshots = "quota_snapshots"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        login = try c.decodeIfPresent(String.self, forKey: .login) ?? "—"
        plan = try c.decodeIfPresent(String.self, forKey: .plan) ?? "unknown"
        resetDate = try c.decodeIfPresent(String.self, forKey: .resetDate)
        snapshots = try c.decodeIfPresent([String: QuotaSnapshot].self, forKey: .snapshots) ?? [:]
    }

    /// The quota that best represents "how much budget is left", preferring metered premium requests.
    var primary: QuotaSnapshot? {
        if let premium = snapshots["premium_interactions"] { return premium }
        return snapshots.values.filter { !$0.unlimited }.max { $0.entitlement < $1.entitlement }
            ?? snapshots.values.first
    }

    var orderedSnapshots: [QuotaSnapshot] {
        let order = ["premium_interactions", "chat", "completions"]
        let known = order.compactMap { snapshots[$0] }
        let rest = snapshots.values
            .filter { !order.contains($0.quotaId) }
            .sorted { $0.quotaId < $1.quotaId }
        return known + rest
    }

    var resetDateDisplay: String? {
        guard let resetDate else { return nil }
        guard let date = Formatters.parseDay(resetDate) else { return resetDate }
        return Formatters.mediumDay(date)
    }

    var daysUntilReset: Int? {
        guard let resetDate else { return nil }
        guard let date = Formatters.parseDay(resetDate) else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: date).day
    }
}

enum QuotaError: LocalizedError, Equatable {
    case missingToken
    case unauthorized
    case noCopilotSeat
    case http(Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "未找到 GitHub Token"
        case .unauthorized: return "Token 无效或已过期"
        case .noCopilotSeat: return "该账号没有 Copilot 订阅"
        case .http(let code): return "GitHub 返回 HTTP \(code)"
        case .transport(let message): return message
        }
    }
}
