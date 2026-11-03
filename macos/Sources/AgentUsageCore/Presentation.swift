import Foundation

public enum Level: Sendable, Equatable {
    case normal, warning, critical

    public init(percent: Double) {
        self = percent >= 90 ? .critical : percent >= 70 ? .warning : .normal
    }
}

public struct UsageRow: Sendable, Equatable {
    public let label: String
    public let percent: Double
    public let resetsAt: Date?

    public var level: Level { Level(percent: percent) }
}

public struct ExtraUsageSummary: Sendable, Equatable {
    /// "$26.66 / $40.00", or "$26.66 used" when there is no limit.
    public let amount: String
    public let percent: Double?
    public let isEnabled: Bool
    /// Human-readable, e.g. "out of credits".
    public let disabledReason: String?
}

public struct CreditsSummary: Sendable, Equatable {
    /// "60,511", or "Unlimited".
    public let balance: String
    /// The plan limit is reached, so Codex is spending credits.
    public let isInUse: Bool
}

public struct ResetsSummary: Sendable, Equatable {
    public let available: Int
    /// When the soonest-expiring reset expires, if known.
    public let nextExpiry: Date?
}

extension ProfileUsage {
    init(claude usage: Usage, subscriptionType: String?) {
        self.init(
            subscriptionType: subscriptionType, rows: usage.rows, extraUsage: usage.extraUsage?.summary,
            credits: nil, resets: nil)
    }

    init(codex usage: CodexUsage, resetCredits: [CodexResetCredit]) {
        let windows = [usage.rateLimit?.primaryWindow, usage.rateLimit?.secondaryWindow].compactMap { $0 }
        let available = usage.rateLimitResetCredits?.availableCount ?? 0
        let expiries = resetCredits.filter { $0.status == "available" }.compactMap { $0.expiresAt.flatMap(parseDate) }
        self.init(
            subscriptionType: usage.planType,
            rows: windows.map {
                UsageRow(
                    label: windowLabel(seconds: $0.limitWindowSeconds), percent: $0.usedPercent,
                    resetsAt: $0.resetAt.map(Date.init(timeIntervalSince1970:)))
            },
            extraUsage: nil,
            credits: usage.credits.flatMap { CreditsSummary($0, limitReached: usage.rateLimit?.limitReached ?? false) },
            resets: available > 0 ? ResetsSummary(available: available, nextExpiry: expiries.min()) : nil
        )
    }
}

extension CreditsSummary {
    /// Nil when there are no credits to spend.
    init?(_ credits: CodexUsage.Credits, limitReached: Bool) {
        if credits.unlimited == true {
            self.init(balance: "Unlimited", isInUse: limitReached)
            return
        }
        guard let balance = credits.balance.flatMap(Double.init), balance > 0 else { return nil }
        let formatted = balance.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
        self.init(balance: formatted, isInUse: limitReached)
    }
}

/// Codex reports windows by length: 5 hours on most plans, plus a week.
func windowLabel(seconds: Double) -> String {
    let hours = Int((seconds / 3600).rounded())
    if hours == 168 { return "Weekly" }
    return hours < 24 ? "Session (\(hours)h)" : "\(Int((Double(hours) / 24).rounded()))-day"
}

extension UsageLimit {
    var label: String {
        switch kind {
        case "session": "Session (5h)"
        case "weekly_all": "Weekly"
        case "weekly_scoped": "Weekly \(scope?.model?.displayName ?? "(scoped)")"
        default: kind
        }
    }
}

extension Usage {
    public var rows: [UsageRow] {
        if let limits, !limits.isEmpty {
            return limits.map { UsageRow(label: $0.label, percent: $0.percent, resetsAt: $0.resetsAt.flatMap(parseDate)) }
        }
        let legacy: [(String, UsageWindow?)] = [
            ("Session (5h)", fiveHour),
            ("Weekly", sevenDay),
            ("Weekly Opus", sevenDayOpus),
            ("Weekly Sonnet", sevenDaySonnet),
            ("Weekly OAuth apps", sevenDayOauthApps),
        ]
        return legacy.compactMap { label, window in
            guard let utilization = window?.utilization else { return nil }
            return UsageRow(label: label, percent: utilization, resetsAt: window?.resetsAt.flatMap(parseDate))
        }
    }
}

extension ExtraUsage {
    /// Nil when extra usage is off and has no limit, i.e. nothing worth showing.
    public var summary: ExtraUsageSummary? {
        let enabled = isEnabled ?? false
        guard enabled || monthlyLimit != nil else { return nil }
        let decimals = decimalPlaces ?? 2
        let code = currency ?? "USD"
        let used = money(usedCredits ?? 0, decimals: decimals, currency: code)
        let amount =
            monthlyLimit.map { "\(used) / \(money($0, decimals: decimals, currency: code))" } ?? "\(used) used"
        return ExtraUsageSummary(
            amount: amount,
            percent: utilization,
            isEnabled: enabled,
            disabledReason: disabledReason?.replacingOccurrences(of: "_", with: " ")
        )
    }
}

/// Puts items in `order`. Items it doesn't mention keep their relative order after the rest.
public func ordered<Item: Identifiable>(_ items: [Item], by order: [Item.ID]) -> [Item] {
    let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    let known = items.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
    return known + items.filter { rank[$0.id] == nil }
}

/// Moves `id` into `target`'s position, shifting the items in between.
public func moving<ID: Equatable>(_ id: ID, to target: ID, in ids: [ID]) -> [ID] {
    guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target), from != to else { return ids }
    var result = ids
    result.remove(at: from)
    result.insert(id, at: to)
    return result
}

/// Where a dragged row lands: it passes a neighbour once its leading edge crosses that neighbour's midpoint.
/// `heights` are the rows' heights in their current order and `offset` is how far the row was dragged.
public func dropIndex(heights: [Double], dragging index: Int, offset: Double) -> Int {
    var target = index
    var passed = 0.0
    if offset > 0 {
        for next in heights.indices.dropFirst(index + 1) {
            guard offset > passed + heights[next] / 2 else { break }
            passed += heights[next]
            target = next
        }
    } else {
        for previous in heights.indices.prefix(index).reversed() {
            guard -offset > passed + heights[previous] / 2 else { break }
            passed += heights[previous]
            target = previous
        }
    }
    return target
}

/// How far a row travels going from index `from` to `to` while the rows in between close up.
public func slotOffset(heights: [Double], from: Int, to: Int) -> Double {
    from < to ? heights[(from + 1)...to].reduce(0, +) : -heights[to..<from].reduce(0, +)
}

func money(_ minor: Double, decimals: Int, currency: String) -> String {
    (minor / pow(10, Double(decimals))).formatted(.currency(code: currency).locale(Locale(identifier: "en_US")))
}

func parseDate(_ string: String) -> Date? {
    try? Date(string, strategy: .iso8601)
}

/// "2h 13m", "1d 8h" or "45m", like the CLI.
public func formatDuration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int((seconds / 60).rounded()))
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes % 60)m" }
    return "\(minutes)m"
}
