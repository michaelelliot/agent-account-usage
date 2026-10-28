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
