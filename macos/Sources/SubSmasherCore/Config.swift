import Foundation

public struct UsageError: LocalizedError, Sendable, Equatable, Codable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// One `[section]` of the config file.
public struct Profile: Sendable, Equatable, Identifiable {
    public let id: String
    public var values: [String: String]

    public init(id: String, values: [String: String] = [:]) {
        self.id = id
        self.values = values
    }

    /// The `name` key if set, otherwise the section id.
    public var displayName: String {
        if let name = values["name"], !name.isEmpty { return name }
        return id
    }
}

/// The INI config shared with the CLI (`~/.config/subsmasher/config`).
public enum ConfigFile {
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["SUBSMASHER_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: expandHome(path))
        }
        return defaultURL(home: URL(fileURLWithPath: NSHomeDirectory()))
    }

    /// `~/.config/subsmasher/config`, or `~/.config/agent-usage/config`, from when this was agent-account-usage, while
    /// only that exists.
    static func defaultURL(home: URL) -> URL {
        let url = home.appending(path: ".config/subsmasher/config")
        let legacy = home.appending(path: ".config/agent-usage/config")
        let files = FileManager.default
        return files.fileExists(atPath: url.path) || !files.fileExists(atPath: legacy.path) ? url : legacy
    }

    public static func load(from url: URL) throws -> [Profile] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UsageError("config file not found: \(url.path)")
        }
        return parse(try String(contentsOf: url, encoding: .utf8))
    }

    /// Sections keep their first-seen order; repeated sections merge, later keys win.
    public static func parse(_ text: String) -> [Profile] {
        var profiles: [Profile] = []
        var current: Int?
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.count > 2, line.hasPrefix("["), line.hasSuffix("]") {
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                if let index = profiles.firstIndex(where: { $0.id == name }) {
                    current = index
                } else {
                    profiles.append(Profile(id: name))
                    current = profiles.count - 1
                }
                continue
            }
            guard let current, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { profiles[current].values[key] = unquote(value) }
        }
        return profiles
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}

public func expandHome(_ path: String) -> String {
    if path == "~" { return NSHomeDirectory() }
    if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst() }
    return path
}
