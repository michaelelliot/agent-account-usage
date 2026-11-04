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
        # Keys: name (optional label), and claude_config_dir, oauth_token, codex_home or cursor_dir.

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

    /// Escalates as the top account nears its limit: the needle climbs, turns orange, then red, then catches fire.
    /// Uses the rounded percentage so the icon agrees with the number beside it.
    var menuBarSymbol: (name: String, color: NSColor?) {
        guard let peak = peakPercent?.rounded() else {
            let name =
                configError != nil || primaryReport != nil
                ? "exclamationmark.triangle" : "gauge.with.dots.needle.bottom.50percent"
            return (name, nil)
        }
        switch peak {
        case ..<50: return ("gauge.with.dots.needle.33percent", nil)
        case ..<75: return ("gauge.with.dots.needle.50percent", nil)
        case ..<90: return ("gauge.with.dots.needle.67percent", .systemOrange)
        case ..<95: return ("gauge.open.with.lines.needle.84percent.exclamation", .systemRed)
        default: return ("flame.fill", .systemRed)
        }
    }

    /// A template image (drawn in the menu bar's own colour) until usage needs attention, then tinted.
    var menuBarImage: NSImage {
        let (name, color) = menuBarSymbol
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Agent usage") ?? NSImage()
        guard let color, let tinted = image.withSymbolConfiguration(.init(paletteColors: [color])) else {
            return image
        }
        tinted.isTemplate = false
        return tinted
    }
}
