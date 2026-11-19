import CryptoKit
import Foundation
import os

public struct Credentials: Sendable, Equatable {
    public let token: String
    public let source: String
    public let subscriptionType: String?
    public let expiresAt: Date?
    /// The keychain item the token was read from, if it came from the keychain.
    public var keychainService: String? = nil
}

private struct StoredCredentials: Decodable {
    struct OAuth: Decodable {
        let accessToken: String?
        let expiresAt: Double?
        let subscriptionType: String?
        let rateLimitTier: String?
    }

    let claudeAiOauth: OAuth?
}

/// The plan to show. Anthropic renamed Max 20x to Ultra (and Max 5x to Max), but Claude Code still stores an Ultra
/// login as `max` with the `default_claude_max_20x` rate limit tier.
func planName(subscriptionType: String?, rateLimitTier: String?) -> String? {
    subscriptionType == "max" && rateLimitTier?.contains("max_20x") == true ? "ultra" : subscriptionType
}

/// The `exp` claim of a JWT access token.
func jwtExpiry(_ token: String) -> Date? {
    let parts = token.split(separator: ".")
    guard parts.count > 1 else { return nil }
    var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64),
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let exp = payload["exp"] as? Double
    else { return nil }
    return Date(timeIntervalSince1970: exp)
}

public enum CredentialStore {
    private static let defaultService = "Claude Code-credentials"

    /// Mirrors how Claude Code names its keychain item for a given CLAUDE_CONFIG_DIR.
    public static func keychainServices(configDir: String) -> [String] {
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        let suffixed = "\(defaultService)-\(hash)"
        // With CLAUDE_CONFIG_DIR unset, Claude Code uses ~/.claude and an unsuffixed service name.
        return configDir == NSHomeDirectory() + "/.claude" ? [defaultService, suffixed] : [suffixed]
    }

    /// What to set CLAUDE_CONFIG_DIR to when running `claude` for these credentials. Claude Code only uses the
    /// unsuffixed keychain item when CLAUDE_CONFIG_DIR is unset, even if it's set to ~/.claude.
    static func claudeConfigDir(for creds: Credentials, configDir: String) -> String? {
        creds.keychainService == defaultService ? nil : configDir
    }

    /// Gets Claude Code to refresh an expired token: `configDir` is what to set CLAUDE_CONFIG_DIR to (nil leaves
    /// it unset), and `claudePath` is the profile's `claude_path`.
    public typealias Refresh = (_ configDir: String?, _ claudePath: String?) -> Void

    /// When a refresh was last tried for each config dir and `claude_path`, so one that fails is retried every
    /// half hour rather than on every refresh. Changing `claude_path` retries straight away.
    private static let refreshAttempts = OSAllocatedUnfairLock(initialState: [String: Date]())
    static let refreshRetryInterval: TimeInterval = 30 * 60

    private static func claimRefreshAttempt(configDir: String, claudePath: String?, now: Date) -> Bool {
        refreshAttempts.withLock { attempts in
            let key = "\(configDir) \(claudePath ?? "")"
            if let last = attempts[key], now.timeIntervalSince(last) < refreshRetryInterval { return false }
            attempts[key] = now
            return true
        }
    }

    /// Reads the profile's token, running `claude` to refresh it if it has expired. Blocks while
    /// `/usr/bin/security` and `claude` run, so call it off the main actor.
    public static func resolve(
        _ profile: Profile, now: Date = .now, refresh: Refresh = refreshWithClaude
    ) throws -> Credentials {
        if let token = profile.values["oauth_token"], !token.isEmpty {
            return Credentials(token: token, source: "oauth_token", subscriptionType: nil, expiresAt: nil)
        }
        guard let dir = profile.values["claude_config_dir"], !dir.isEmpty else {
            throw UsageError("section needs setup_token, claude_config_dir, oauth_token, codex_home or cursor_dir")
        }

        let configDir = URL(fileURLWithPath: expandHome(dir)).standardizedFileURL.path
        guard var creds = try readConfigDir(configDir) else {
            throw UsageError(
                "no Claude Code login found for \(configDir) (run: CLAUDE_CONFIG_DIR=\(configDir) claude /login)")
        }
        let claudeConfigDir = claudeConfigDir(for: creds, configDir: configDir)
        let claudePath = profile.values["claude_path"]
        if let expiresAt = creds.expiresAt, expiresAt <= now,
            claimRefreshAttempt(configDir: configDir, claudePath: claudePath, now: now)
        {
            refresh(claudeConfigDir, claudePath)
            creds = try readConfigDir(configDir) ?? creds
        }
        if let expiresAt = creds.expiresAt, expiresAt <= now {
            let when = expiresAt.formatted(date: .abbreviated, time: .shortened)
            let command = claudeConfigDir.map { "claude with CLAUDE_CONFIG_DIR=\($0)" } ?? "claude"
            throw UsageError("access token expired \(when) (run \(command) to refresh it)")
        }
        return creds
    }

    /// The `claude_path` if set, else `claude` on PATH or where Claude Code's installers put it. An app opened
    /// from Finder gets a minimal PATH, so the install locations matter there.
    static func findClaude(claudePath: String?) -> String? {
        if let claudePath, !claudePath.isEmpty { return expandHome(claudePath) }
        let home = NSHomeDirectory()
        let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        let installed = [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return (onPath + installed).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs Claude Code's `/cost` command, which makes it refresh an expired access token and save the new one
    /// itself. `/cost` runs locally, so the model isn't called. Project settings and MCP servers in the working
    /// directory are skipped, as it isn't one we control. Waits up to a minute.
    public static func refreshWithClaude(configDir: String?, claudePath: String?) {
        guard let claude = findClaude(claudePath: claudePath) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = [
            "-p", "/cost", "--no-session-persistence", "--setting-sources", "user", "--strict-mcp-config",
        ]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = configDir
        // An npm-installed claude runs under node, which is usually next to it but not on an app's minimal PATH.
        let claudeDir = URL(fileURLWithPath: claude).deletingLastPathComponent().path
        environment["PATH"] = [claudeDir, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return
        }
        if exited.wait(timeout: .now() + 60) == .timedOut { process.terminate() }
    }

    static func readConfigDir(_ configDir: String) throws -> Credentials? {
        for service in keychainServices(configDir: configDir) {
            if let raw = readKeychain(service: service) {
                var creds = try parse(Data(raw.utf8), source: "keychain \"\(service)\"")
                creds.keychainService = service
                return creds
            }
        }
        let file = URL(fileURLWithPath: configDir).appending(path: ".credentials.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try parse(data, source: file.path)
    }

    // Uses the `security` tool rather than the Security framework because Claude Code's keychain
    // items already trust it, so reading them doesn't prompt.
    static func readKeychain(service: String, account: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        let account = account ?? ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        process.arguments = ["find-generic-password", "-a", account, "-w", "-s", service]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !output.isEmpty ? output : nil
    }

    static func parse(_ data: Data, source: String) throws -> Credentials {
        guard let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data) else {
            throw UsageError("could not parse credentials from \(source)")
        }
        guard let oauth = stored.claudeAiOauth, let token = oauth.accessToken, !token.isEmpty else {
            throw UsageError("no Claude.ai OAuth token in \(source)")
        }
        return Credentials(
            token: token,
            source: source,
            subscriptionType: planName(subscriptionType: oauth.subscriptionType, rateLimitTier: oauth.rateLimitTier),
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}
