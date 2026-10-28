import AgentUsageCore
import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class UsageModel {
    private(set) var reports: [ProfileReport] = []
    private(set) var configError: String?
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?

    let configURL = ConfigFile.defaultURL

    private static let refreshInterval: Duration = .seconds(300)
    private static let staleAfter: TimeInterval = 60
    private static let orderKey = "profileOrder"
    private static let configTemplate = """
        # agent-usage profiles: one [section] per account.
        # Keys: name (optional label), claude_config_dir or oauth_token.

        [default]
        claude_config_dir = ~/.claude

        """

    init() {
        Task { await refreshLoop() }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let profiles = try ConfigFile.load(from: configURL)
            configError = profiles.isEmpty ? "no profiles in \(configURL.path)" : nil
            let fetched = await fetchReports(for: profiles)
            // Read the order after fetching so a drag made during the refresh isn't undone.
            reports = ordered(fetched, by: savedOrder)
        } catch {
            configError = error.localizedDescription
            reports = []
        }
        lastUpdated = .now
    }

    /// The display order the user dragged the profiles into. Kept in UserDefaults, not the shared config.
    private var savedOrder: [String] {
        UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
    }

    /// Moves a profile into another's position. Returns false if either isn't shown.
    @discardableResult
    func move(_ id: String, to target: String) -> Bool {
        let ids = reports.map(\.id)
        guard ids.contains(id), ids.contains(target) else { return false }
        let newOrder = moving(id, to: target, in: ids)
        reports = ordered(reports, by: newOrder)
        UserDefaults.standard.set(newOrder, forKey: Self.orderKey)
        return true
    }

    func refreshIfStale() {
        if let lastUpdated, Date.now.timeIntervalSince(lastUpdated) < Self.staleAfter { return }
        Task { await refresh() }
    }

    /// Opens the config in the default text editor, creating a starter file if there isn't one.
    func openConfig() {
        let files = FileManager.default
        if !files.fileExists(atPath: configURL.path) {
            try? files.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Self.configTemplate.write(to: configURL, atomically: true, encoding: .utf8)
        }
        let workspace = NSWorkspace.shared
        if let editor = workspace.urlForApplication(toOpen: .plainText) {
            workspace.open([configURL], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.open(configURL)
        }
    }

    /// The profile summarised in the menu bar: $AGENT_USAGE_PROFILE, [default], or the first one.
    private var primaryReport: ProfileReport? {
        let preferred = ProcessInfo.processInfo.environment["AGENT_USAGE_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
        return reports.first { $0.id == (preferred ?? "default") } ?? reports.first
    }

    /// Highest utilization across the primary profile's windows.
    var peakPercent: Double? {
        guard case let .success(profile)? = primaryReport?.result else { return nil }
        return profile.usage.rows.map(\.percent).max()
    }

    var menuBarText: String? {
        peakPercent.map { "\(Int($0.rounded()))%" }
    }

    var symbolName: String {
        guard let peak = peakPercent else {
            return configError != nil || primaryReport != nil
                ? "exclamationmark.triangle" : "gauge.with.dots.needle.bottom.50percent"
        }
        switch peak {
        case ..<17: return "gauge.with.dots.needle.0percent"
        case ..<42: return "gauge.with.dots.needle.33percent"
        case ..<58: return "gauge.with.dots.needle.50percent"
        case ..<84: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }
}
