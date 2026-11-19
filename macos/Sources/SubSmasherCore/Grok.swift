import CommonCrypto
import Foundation
import SQLite3

/// From GetSandUsageStatus, which is what Grok Bot shows as its weekly usage.
public struct GrokUsage: Decodable, Sendable {
    public let currentPeriodStart: String?
    public let nextResetTimestampUtc: String?
    public let usagePercent: Double?
    public let availableBankedResetCount: ProtoInt64?
    public let usesPooledEnterpriseAllowance: Bool?
    public let grokPlanLabel: String?
    public let cursorPlanName: String?
    public let isUnified: Bool?
}

/// A one-off reset of the weekly limit, from ListSandBankedResets.
public struct GrokBankedReset: Decodable, Sendable {
    public let expiresAt: String?
}

private struct GrokBankedResetList: Decodable {
    let resets: [GrokBankedReset]?
}

/// Protobuf JSON writes int64 as a string.
public struct ProtoInt64: Decodable, Sendable {
    public let value: Int

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), let value = Int(string) {
            self.value = value
        } else {
            value = try container.decode(Int.self)
        }
    }
}

public enum GrokAuth {
    static let encryptedPrefix = "cursor-safe-storage:v1:"

    /// Reads the token Cursor saved for its signed-in account. Grok Bot is a Cursor app and signs in
    /// with a Cursor account, but keeps its own copy where it can't be read. Never refreshes it.
    public static func resolve(cursorDir: String, now: Date = .now) throws -> String {
        let dir = URL(fileURLWithPath: expandHome(cursorDir)).standardizedFileURL.path
        let database = URL(fileURLWithPath: dir).appending(path: "User/globalStorage/state.vscdb").path
        guard let stored = try readStoredToken(database: database, dir: dir) else {
            throw UsageError("no Cursor login found in \(dir) (sign in to Cursor)")
        }
        var token = stored
        if stored.hasPrefix(encryptedPrefix) {
            guard let password = CredentialStore.readKeychain(service: "Cursor Safe Storage", account: "Cursor Key")
            else {
                throw UsageError(
                    "could not read the \"Cursor Safe Storage\" key from the keychain (allow access when macOS asks)")
            }
            token = try decrypt(stored, password: password)
        }
        if let expiresAt = jwtExpiry(token), expiresAt <= now {
            let when = expiresAt.formatted(date: .abbreviated, time: .shortened)
            throw UsageError("access token expired \(when) (open Cursor to refresh it)")
        }
        return token
    }

    static func readStoredToken(database: String, dir: String) throws -> String? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            sqlite3_busy_timeout(db, 2000) == SQLITE_OK,
            sqlite3_prepare_v2(
                db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'", -1, &statement, nil)
                == SQLITE_OK
        else { throw UsageError("no Cursor data found in \(dir)") }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    /// Cursor encrypts its tokens with Electron safeStorage: "v10" + AES-128-CBC, keyed by
    /// PBKDF2(the "Cursor Safe Storage" keychain password, "saltysalt", 1003 rounds).
    static func decrypt(_ stored: String, password: String) throws -> String {
        let failure = UsageError("could not decrypt Cursor's saved login")
        guard let blob = Data(base64Encoded: String(stored.dropFirst(encryptedPrefix.count))), blob.count > 3 else {
            throw failure
        }
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let ciphertext = Array(blob.dropFirst(3))
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var length = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key, key.count,
            iv, ciphertext, ciphertext.count, &plaintext, plaintext.count, &length)
        guard status == kCCSuccess, let token = String(bytes: plaintext.prefix(length), encoding: .utf8) else {
            throw failure
        }
        return token
    }
}

public enum GrokClient {
    /// Cursor's API, which Grok Bot uses. Undocumented, like the others.
    public static let baseURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService")!

    public static func fetch(
        token: String, session: URLSession = .shared
    ) async throws -> (usage: GrokUsage, bankedResets: [GrokBankedReset]) {
        let usage: GrokUsage
        do {
            usage = try JSONDecoder().decode(GrokUsage.self, from: try await call("GetSandUsageStatus", token, session))
        } catch let error as DecodingError {
            throw UsageError("unexpected usage response: \(error.localizedDescription)")
        }
        // Only the reset expiry dates need this second call, so it's skipped when there are none
        // and a failure just leaves them out.
        guard usage.availableBankedResetCount?.value ?? 0 > 0,
            let data = try? await call("ListSandBankedResets", token, session),
            let list = try? JSONDecoder().decode(GrokBankedResetList.self, from: data)
        else { return (usage, []) }
        return (usage, list.resets ?? [])
    }

    private static func call(_ method: String, _ token: String, _ session: URLSession) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: method), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UsageError("HTTP \(status): \(UsageClient.errorMessage(data))")
        }
        return data
    }
}
