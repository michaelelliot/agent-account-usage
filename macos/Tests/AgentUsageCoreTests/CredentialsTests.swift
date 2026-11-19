import Foundation
import Testing

@testable import AgentUsageCore

struct CredentialsTests {
    @Test func suffixesServiceWithSha256OfConfigDir() {
        // sha256("/Users/someone/.claude-work") computed with `shasum -a 256`
        #expect(CredentialStore.keychainServices(configDir: "/Users/someone/.claude-work") == [
            "Claude Code-credentials-18cc900a"
        ])
    }

    @Test func triesUnsuffixedServiceFirstForDefaultDir() {
        let services = CredentialStore.keychainServices(configDir: NSHomeDirectory() + "/.claude")
        #expect(services.count == 2)
        #expect(services[0] == "Claude Code-credentials")
        #expect(services[1].hasPrefix("Claude Code-credentials-"))
    }

    @Test func usesOauthTokenEvenWhenConfigDirIsSet() throws {
        let creds = try CredentialStore.resolve(
            Profile(id: "p", values: ["oauth_token": "tok", "claude_config_dir": "/nowhere"]))
        #expect(creds == Credentials(token: "tok", source: "oauth_token", subscriptionType: nil, expiresAt: nil))
    }

    @Test func rejectsSectionWithoutCredentialKeys() {
        #expect(throws: UsageError("section needs setup_token, claude_config_dir, oauth_token, codex_home or cursor_dir")) {
            try CredentialStore.resolve(Profile(id: "p"))
        }
    }

    @Test func readsCredentialsFileWhenThereIsNoKeychainItem() throws {
        let expiresAt = Date.now.addingTimeInterval(3600)
        let dir = try credentialsDir(accessToken: "file-tok", expiresAt: expiresAt, subscriptionType: "pro")
        defer { try? FileManager.default.removeItem(at: dir) }

        let creds = try CredentialStore.resolve(Profile(id: "p", values: ["claude_config_dir": dir.path + "/"]))
        #expect(creds.token == "file-tok")
        #expect(creds.subscriptionType == "pro")
        #expect(abs(creds.expiresAt!.timeIntervalSince(expiresAt)) < 0.01)
    }

    @Test func runsClaudeToRefreshExpiredTokenThenRereadsIt() throws {
        let dir = try credentialsDir(accessToken: "old", expiresAt: Date.now.addingTimeInterval(-1))
        defer { try? FileManager.default.removeItem(at: dir) }

        var calls: [[String?]] = []
        let creds = try CredentialStore.resolve(
            Profile(id: "p", values: ["claude_config_dir": dir.path + "/", "claude_path": "/opt/claude"])
        ) { configDir, claudePath in
            calls.append([configDir, claudePath])
            #expect(throws: Never.self) {
                try credentialsDir(accessToken: "new", expiresAt: Date.now.addingTimeInterval(3600), at: dir)
            }
        }
        #expect(calls == [[dir.path, "/opt/claude"]])
        #expect(creds.token == "new")
    }

    @Test func retriesRefreshingAnExpiredTokenAfterAWhileOrWhenClaudePathChanges() throws {
        let expiresAt = Date.now.addingTimeInterval(-1)
        let dir = try credentialsDir(accessToken: "old", expiresAt: expiresAt)
        let otherDir = try credentialsDir(accessToken: "old", expiresAt: expiresAt)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: otherDir)
        }

        /// Whether resolving the profile at `now` ran a refresh.
        func refreshes(_ dir: URL, at now: Date, claudePath: String? = nil) -> Bool {
            var values = ["claude_config_dir": dir.path]
            values["claude_path"] = claudePath
            var refreshed = false
            do {
                _ = try CredentialStore.resolve(Profile(id: "p", values: values), now: now) { _, _ in refreshed = true }
                #expect(now < expiresAt)
            } catch {
                let message = (error as? UsageError)?.message ?? ""
                #expect(message.hasPrefix("access token expired"))
                #expect(message.hasSuffix("(run claude with CLAUDE_CONFIG_DIR=\(dir.path) to refresh it)"))
            }
            return refreshed
        }
        let start = Date.now
        #expect(!refreshes(dir, at: expiresAt.addingTimeInterval(-10)), "token still valid")
        #expect(refreshes(dir, at: start))
        #expect(!refreshes(dir, at: start.addingTimeInterval(60)), "tried within the last half hour")
        #expect(refreshes(otherDir, at: start.addingTimeInterval(60)), "another config dir")
        #expect(refreshes(dir, at: start.addingTimeInterval(120), claudePath: "/opt/claude"), "claude_path changed")
        #expect(refreshes(dir, at: start.addingTimeInterval(CredentialStore.refreshRetryInterval + 1)))
    }

    @Test func runsClaudeCostWithTheConfigDirAndClaudesDirFirstOnPath() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "agent-usage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A fake claude that writes its arguments, CLAUDE_CONFIG_DIR and PATH next to itself.
        let claude = dir.appending(path: "claude")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$*\" \"${CLAUDE_CONFIG_DIR-unset}\" \"$PATH\" > \"$0.out\"\n"
        try script.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        for configDir in ["/Users/me/.claude-work", nil] {
            CredentialStore.refreshWithClaude(configDir: configDir, claudePath: claude.path)
            let out = try String(contentsOf: claude.appendingPathExtension("out"), encoding: .utf8)
            let lines = out.split(separator: "\n").map(String.init)
            #expect(lines.count == 3)
            #expect(lines.first == "-p /cost --no-session-persistence --setting-sources user --strict-mcp-config")
            #expect(lines.dropFirst().first == configDir ?? "unset")
            #expect(lines.last?.hasPrefix(dir.path + ":") == true)
        }
    }

    @Test func leavesClaudeConfigDirUnsetForTheUnsuffixedKeychainItem() {
        let creds = Credentials(
            token: "t", source: "keychain", subscriptionType: nil, expiresAt: nil,
            keychainService: "Claude Code-credentials")
        #expect(CredentialStore.claudeConfigDir(for: creds, configDir: "/Users/me/.claude") == nil)
    }

    @Test func reportsConfigDirWithNoLogin() {
        let error = #expect(throws: UsageError.self) {
            try CredentialStore.resolve(Profile(id: "p", values: ["claude_config_dir": "/nonexistent/agent-usage"]))
        }
        #expect(error?.message.hasPrefix("no Claude Code login found for /nonexistent/agent-usage") == true)
    }

    private func credentialsDir(
        accessToken: String, expiresAt: Date, subscriptionType: String? = nil, at existing: URL? = nil
    ) throws -> URL {
        let dir =
            existing ?? FileManager.default.temporaryDirectory.appending(path: "agent-usage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var oauth: [String: Any] = ["accessToken": accessToken, "expiresAt": expiresAt.timeIntervalSince1970 * 1000]
        oauth["subscriptionType"] = subscriptionType
        let data = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        try data.write(to: dir.appending(path: ".credentials.json"))
        return dir
    }
}
