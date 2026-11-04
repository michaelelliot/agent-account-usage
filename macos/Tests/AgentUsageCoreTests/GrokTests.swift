import Foundation
import Testing

@testable import AgentUsageCore

struct GrokTests {
    // Trimmed from a real GetSandUsageStatus response.
    static let response = """
        {
          "currentPeriodStart": "2026-10-30T14:24:32.444Z",
          "nextResetTimestampUtc": "2026-11-06T14:24:32.444Z",
          "usagePercent": 31.892770105605198,
          "hasAvailableUsage": true,
          "hasNonZeroIncludedLimit": true,
          "onDemandSettings": {"visible": true, "eligible": true},
          "grokPlanLabel": "Grok Bot Plan",
          "cursorPlanName": "Ultra",
          "isUnified": true,
          "billingBrand": "SAND_BILLING_BRAND_GROK"
        }
        """

    static func decode(_ json: String) throws -> GrokUsage {
        try JSONDecoder().decode(GrokUsage.self, from: Data(json.utf8))
    }

    @Test func profileUsageFromGrokResponse() throws {
        let profile = ProfileUsage(grok: try Self.decode(Self.response), bankedResets: [])
        #expect(profile.subscriptionType == "Ultra")
        #expect(profile.rows == [
            UsageRow(label: "Weekly", percent: 31.892770105605198, resetsAt: UsageTests.date("2026-11-06T14:24:32.444Z"))
        ])
        #expect(profile.resets == nil)
    }

    @Test func bankedResetsCountFromStringAndSoonestExpiry() throws {
        let usage = try Self.decode(#"{"usagePercent": 100, "availableBankedResetCount": "2", "grokPlanLabel": "SuperGrok"}"#)
        let resets = try JSONDecoder().decode(
            [GrokBankedReset].self,
            from: Data(#"[{"expiresAt": "2026-11-20T00:00:00Z"}, {"expiresAt": "2026-11-01T15:30:00Z"}]"#.utf8))
        let profile = ProfileUsage(grok: usage, bankedResets: resets)
        #expect(profile.subscriptionType == "SuperGrok")
        #expect(profile.rows == [UsageRow(label: "Weekly", percent: 100, resetsAt: nil)])
        #expect(profile.resets == ResetsSummary(available: 2, nextExpiry: UsageTests.date("2026-11-01T15:30:00Z")))
    }

    @Test func pooledEnterpriseAllowanceHasNoRows() throws {
        let usage = try Self.decode(#"{"usagePercent": 5, "usesPooledEnterpriseAllowance": true}"#)
        #expect(ProfileUsage(grok: usage, bankedResets: []).rows.isEmpty)
    }

    @Test func decryptsElectronSafeStorage() throws {
        // Encrypted with node:crypto the way Electron does on macOS, using password "test-password".
        let stored = "cursor-safe-storage:v1:djEwaTKn8QSpJ4aIH7pIsFHxMWdeVpGH4Q7X7hMfDsr+cpE="
        #expect(try GrokAuth.decrypt(stored, password: "test-password") == "header.payload.signature")
        #expect(throws: UsageError("could not decrypt Cursor's saved login")) {
            try GrokAuth.decrypt(stored, password: "wrong")
        }
    }

    @Test func readsCursorsSavedToken() throws {
        let token = CodexTests.jwt(exp: Date.now.addingTimeInterval(3600).timeIntervalSince1970)
        let dir = try Self.cursorDir(token: token)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try GrokAuth.resolve(cursorDir: dir.path + "/") == token)
    }

    @Test func rejectsExpiredToken() throws {
        let dir = try Self.cursorDir(token: CodexTests.jwt(exp: Date.now.timeIntervalSince1970 - 60))
        defer { try? FileManager.default.removeItem(at: dir) }
        let error = #expect(throws: UsageError.self) { try GrokAuth.resolve(cursorDir: dir.path) }
        #expect(error?.message.hasPrefix("access token expired") == true)
    }

    @Test func reportsSignedOutCursor() throws {
        let dir = try Self.cursorDir(token: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        let error = #expect(throws: UsageError.self) { try GrokAuth.resolve(cursorDir: dir.path) }
        #expect(error?.message.hasPrefix("no Cursor login found in") == true)
    }

    @Test func reportsDirWithNoCursorData() {
        #expect(throws: UsageError("no Cursor data found in /nonexistent/Cursor")) {
            try GrokAuth.resolve(cursorDir: "/nonexistent/Cursor")
        }
    }

    @Test func cursorErrorMessage() {
        #expect(UsageClient.errorMessage(Data(#"{"code":"unauthenticated","message":"Not logged in"}"#.utf8))
            == "Not logged in")
    }

    /// A Cursor data dir whose state.vscdb holds `token` unencrypted, as Cursor stores it without an OS keychain.
    static func cursorDir(token: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "agent-usage-test-\(UUID().uuidString)")
        let storage = dir.appending(path: "User/globalStorage")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        var sql = "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);"
        if let token { sql += "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)');" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [storage.appending(path: "state.vscdb").path, sql]
        try process.run()
        process.waitUntilExit()
        return dir
    }
}
