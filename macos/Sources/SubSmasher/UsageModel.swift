import SubSmasherCore
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

    var configURL: URL { ConfigFile.defaultURL }

    private static let refreshInterval: Duration = .seconds(300)
    private static let staleAfter: TimeInterval = 60
    private static let orderKey = "profileOrder"
    private static let configTemplate = """
        # SubSmasher profiles: one [section] per account.
        # Keys: name (optional label), and setup_token, claude_config_dir, oauth_token, codex_home or cursor_dir.

        [default]
        claude_config_dir = ~/.claude

        """

    init() {
        Self.adoptAgentUsageDefaults()
        Task { await refreshLoop() }
    }

    /// Takes over the saved order, setup-token check state and menu bar position the app had as Agent Usage, before it
    /// was renamed. Only in the app itself: an unbundled `swift run` or a test runner keeps its defaults elsewhere.
    private static func adoptAgentUsageDefaults() {
        let agentUsage = "local.agent-account-usage.AgentUsage"
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier == "local.subsmasher.SubSmasher",
            let saved = defaults.persistentDomain(forName: agentUsage)
        else { return }
        for (key, value) in saved where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.removePersistentDomain(forName: agentUsage)
    }

    /// Shows `reports` as just fetched, without reading the config or refreshing. For the README's screenshots.
    init(reports: [ProfileReport]) {
        self.reports = reports
        lastUpdated = .now
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refresh(.timer)
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func refresh(_ trigger: RefreshTrigger) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let profiles = try ConfigFile.load(from: configURL)
            configError = profiles.isEmpty ? "no profiles in \(configURL.path)" : nil
            let fetched = await fetchReports(for: profiles, trigger: trigger)
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
        Task { await refresh(.menuOpened) }
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

    /// The profile summarised in the menu bar: whichever is at the top of the list.
    private var primaryReport: ProfileReport? { reports.first }

    /// Highest utilization across the primary profile's windows.
    var peakPercent: Double? {
        guard case let .success(profile)? = primaryReport?.result else { return nil }
        return profile.rows.map(\.percent).max()
    }

    var menuBarText: String? {
        peakPercent.map { "\(Int($0.rounded()))%" }
    }

    /// The plush toy hugging a gauge whose needle shows the top account's usage, in the menu bar's own colour while
    /// there's plenty left, then yellow from 60%, orange from 70% and red from 90%, as the menu's bars turn orange and
    /// red. A warning triangle when the config can't be read or the top account has no usage to show. Uses the rounded
    /// percentage so the icon agrees with the number beside it.
    var menuBarImage: NSImage {
        guard let peak = peakPercent?.rounded() else {
            guard configError == nil, primaryReport == nil else {
                return NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "SubSmasher")
                    ?? NSImage()
            }
            return MenuBarIcon.image(percent: nil, color: nil)
        }
        let color: NSColor? =
            switch peak {
            case ..<60: nil
            case ..<70: MenuBarIcon.yellow
            case ..<90: .systemOrange
            default: .systemRed
            }
        return MenuBarIcon.image(percent: peak, color: color)
    }
}
