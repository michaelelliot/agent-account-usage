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
        #expect(throws: UsageError("section needs claude_config_dir, oauth_token or codex_home")) {
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

    @Test func rejectsExpiredAccessToken() throws {
        let dir = try credentialsDir(accessToken: "old", expiresAt: Date.now.addingTimeInterval(-1))
        defer { try? FileManager.default.removeItem(at: dir) }

        let error = #expect(throws: UsageError.self) {
            try CredentialStore.resolve(Profile(id: "p", values: ["claude_config_dir": dir.path]))
        }
        #expect(error?.message.hasPrefix("access token expired") == true)
    }

    @Test func reportsConfigDirWithNoLogin() {
        let error = #expect(throws: UsageError.self) {
            try CredentialStore.resolve(Profile(id: "p", values: ["claude_config_dir": "/nonexistent/agent-usage"]))
        }
        #expect(error?.message.hasPrefix("no Claude Code login found for /nonexistent/agent-usage") == true)
    }

    private func credentialsDir(accessToken: String, expiresAt: Date, subscriptionType: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "agent-usage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var oauth: [String: Any] = ["accessToken": accessToken, "expiresAt": expiresAt.timeIntervalSince1970 * 1000]
        oauth["subscriptionType"] = subscriptionType
        let data = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        try data.write(to: dir.appending(path: ".credentials.json"))
        return dir
    }
}
