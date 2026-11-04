import CryptoKit
import Foundation

public struct Credentials: Sendable, Equatable {
    public let token: String
    public let source: String
    public let subscriptionType: String?
    public let expiresAt: Date?
}

private struct StoredCredentials: Decodable {
    struct OAuth: Decodable {
        let accessToken: String?
        let expiresAt: Double?
        let subscriptionType: String?
    }

    let claudeAiOauth: OAuth?
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
    /// Mirrors how Claude Code names its keychain item for a given CLAUDE_CONFIG_DIR.
    public static func keychainServices(configDir: String) -> [String] {
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        let suffixed = "Claude Code-credentials-\(hash)"
        // With CLAUDE_CONFIG_DIR unset, Claude Code uses ~/.claude and an unsuffixed service name.
        return configDir == NSHomeDirectory() + "/.claude" ? ["Claude Code-credentials", suffixed] : [suffixed]
    }

    /// Reads the profile's token. Blocks while `/usr/bin/security` runs, so call it off the main actor.
    public static func resolve(_ profile: Profile, now: Date = .now) throws -> Credentials {
        if let token = profile.values["oauth_token"], !token.isEmpty {
            return Credentials(token: token, source: "oauth_token", subscriptionType: nil, expiresAt: nil)
        }
        guard let dir = profile.values["claude_config_dir"], !dir.isEmpty else {
            throw UsageError("section needs claude_config_dir, oauth_token, codex_home or cursor_dir")
        }

        let configDir = URL(fileURLWithPath: expandHome(dir)).standardizedFileURL.path
        guard let creds = try readConfigDir(configDir) else {
            throw UsageError(
                "no Claude Code login found for \(configDir) (run: CLAUDE_CONFIG_DIR=\(configDir) claude /login)")
        }
        if let expiresAt = creds.expiresAt, expiresAt <= now {
            let when = expiresAt.formatted(date: .abbreviated, time: .shortened)
            throw UsageError(
                "access token expired \(when) (run claude with CLAUDE_CONFIG_DIR=\(configDir) to refresh it)")
        }
        return creds
    }

    static func readConfigDir(_ configDir: String) throws -> Credentials? {
        for service in keychainServices(configDir: configDir) {
            if let raw = readKeychain(service: service) {
                return try parse(Data(raw.utf8), source: "keychain \"\(service)\"")
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
            subscriptionType: oauth.subscriptionType,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}
