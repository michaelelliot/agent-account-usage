import Foundation
import Testing

@testable import AgentUsageCore

struct CodexTests {
    // Trimmed from a real /wham/usage response.
    static let response = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "allowed": false, "limit_reached": true,
            "primary_window": {"used_percent": 100, "limit_window_seconds": 604800,
                               "reset_after_seconds": 41251, "reset_at": 1793774149},
            "secondary_window": null
          },
          "code_review_rate_limit": null,
          "credits": {"has_credits": true, "unlimited": false, "overage_limit_reached": false,
                      "balance": "60511.4630200000"},
          "rate_limit_reset_credits": {"available_count": 3, "applicable_available_count": 3}
        }
        """

    static func resetCredit(_ status: String, _ expiresAt: String?) throws -> CodexResetCredit {
        let json = try JSONSerialization.data(withJSONObject: ["status": status, "expires_at": expiresAt as Any])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CodexResetCredit.self, from: json)
    }

    @Test func profileUsageFromCodexResponse() throws {
        let usage = try CodexUsage.decode(Data(Self.response.utf8))
        let resetCredits = try [
            Self.resetCredit("redeemed", "2026-10-29T00:00:00Z"),
            Self.resetCredit("available", "2026-12-01T22:27:46.796390Z"),
            Self.resetCredit("available", "2026-11-06T23:21:35.660200Z"),
        ]
        let profile = ProfileUsage(codex: usage, resetCredits: resetCredits)
        #expect(profile.subscriptionType == "pro")
        #expect(profile.rows == [
            UsageRow(label: "Weekly", percent: 100, resetsAt: Date(timeIntervalSince1970: 1_793_774_149))
        ])
        #expect(profile.credits == CreditsSummary(balance: "60,511", isInUse: true))
        #expect(profile.resets == ResetsSummary(
            available: 3, nextExpiry: UsageTests.date("2026-11-06T23:21:35.660200Z")))
        #expect(profile.extraUsage == nil)
    }

    @Test func emptyCreditsAndResetsAreHidden() throws {
        let usage = try CodexUsage.decode(
            Data(
                """
                {"plan_type": "plus",
                 "rate_limit": {"limit_reached": false,
                   "primary_window": {"used_percent": 12, "limit_window_seconds": 18000, "reset_at": null},
                   "secondary_window": {"used_percent": 40, "limit_window_seconds": 604800, "reset_at": null}},
                 "credits": {"has_credits": false, "unlimited": false, "balance": "0"},
                 "rate_limit_reset_credits": {"available_count": 0}}
                """.utf8))
        let profile = ProfileUsage(codex: usage, resetCredits: [])
        #expect(profile.rows == [
            UsageRow(label: "Session (5h)", percent: 12, resetsAt: nil),
            UsageRow(label: "Weekly", percent: 40, resetsAt: nil),
        ])
        #expect(profile.credits == nil)
        #expect(profile.resets == nil)
    }

    @Test func resetsWithoutExpiryDatesStillShowTheCount() throws {
        let profile = ProfileUsage(codex: try CodexUsage.decode(Data(Self.response.utf8)), resetCredits: [])
        #expect(profile.resets == ResetsSummary(available: 3, nextExpiry: nil))
    }

    @Test func windowLabels() {
        #expect(windowLabel(seconds: 18000) == "Session (5h)")
        #expect(windowLabel(seconds: 604_800) == "Weekly")
        #expect(windowLabel(seconds: 2_592_000) == "30-day")
    }

    @Test func readsTokenAccountAndExpiryFromAuthFile() throws {
        let exp = Date.now.addingTimeInterval(3600).timeIntervalSince1970.rounded()
        let token = Self.jwt(exp: exp)
        let dir = try Self.authDir(["auth_mode": "chatgpt", "tokens": ["access_token": token, "account_id": "acct"]])
        defer { try? FileManager.default.removeItem(at: dir) }

        let creds = try CodexAuth.resolve(codexHome: dir.path + "/")
        #expect(creds == CodexCredentials(
            token: token, accountID: "acct", source: dir.appending(path: "auth.json").path,
            expiresAt: Date(timeIntervalSince1970: exp)))
    }

    @Test func rejectsExpiredToken() throws {
        let dir = try Self.authDir(["tokens": ["access_token": Self.jwt(exp: Date.now.timeIntervalSince1970 - 60)]])
        defer { try? FileManager.default.removeItem(at: dir) }

        let error = #expect(throws: UsageError.self) { try CodexAuth.resolve(codexHome: dir.path) }
        #expect(error?.message.hasPrefix("access token expired") == true)
    }

    @Test func rejectsApiKeyLogin() throws {
        let dir = try Self.authDir(["auth_mode": "apikey", "OPENAI_API_KEY": "sk-...", "tokens": NSNull()])
        defer { try? FileManager.default.removeItem(at: dir) }

        let error = #expect(throws: UsageError.self) { try CodexAuth.resolve(codexHome: dir.path) }
        #expect(error?.message.hasPrefix("no ChatGPT login in") == true)
    }

    @Test func reportsCodexHomeWithNoLogin() {
        let error = #expect(throws: UsageError.self) { try CodexAuth.resolve(codexHome: "/nonexistent/agent-usage") }
        #expect(error?.message.hasPrefix("no Codex login found in /nonexistent/agent-usage") == true)
    }

    @Test func chatGPTErrorDetail() {
        #expect(UsageClient.errorMessage(Data(#"{"detail":"Unauthorized"}"#.utf8)) == "Unauthorized")
    }

    /// An unsigned JWT; only the payload's exp is read.
    static func jwt(exp: Double) -> String {
        func part(_ object: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(part(["alg": "none"])).\(part(["exp": exp])).sig"
    }

    static func authDir(_ contents: [String: Any]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "agent-usage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: contents).write(to: dir.appending(path: "auth.json"))
        return dir
    }
}
