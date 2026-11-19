import Foundation

public struct CodexCredentials: Sendable, Equatable {
    public let token: String
    public let accountID: String?
    public let source: String
    public let expiresAt: Date?
}

private struct CodexAuthFile: Decodable {
    struct Tokens: Decodable {
        let accessToken: String?
        let accountId: String?
    }

    let tokens: Tokens?
}

public struct CodexUsage: Decodable, Sendable {
    public struct Window: Decodable, Sendable {
        public let usedPercent: Double
        public let limitWindowSeconds: Double
        /// Unix seconds.
        public let resetAt: Double?
    }

    public struct RateLimit: Decodable, Sendable {
        public let limitReached: Bool?
        public let primaryWindow: Window?
        public let secondaryWindow: Window?
    }

    /// Spent once a limit is reached. `balance` is a decimal string, e.g. "60511.4630200000".
    public struct Credits: Decodable, Sendable {
        public let unlimited: Bool?
        public let balance: String?
    }

    public struct ResetCredits: Decodable, Sendable {
        public let availableCount: Int?
    }

    public let planType: String?
    public let rateLimit: RateLimit?
    public let credits: Credits?
    public let rateLimitResetCredits: ResetCredits?

    public static func decode(_ data: Data) throws -> CodexUsage {
        try snakeCaseDecoder.decode(CodexUsage.self, from: data)
    }
}

/// A one-off full reset of the usage limits, from /wham/rate-limit-reset-credits.
public struct CodexResetCredit: Decodable, Sendable {
    public let status: String
    public let expiresAt: String?
}

private struct CodexResetCreditList: Decodable {
    let credits: [CodexResetCredit]
}

private let snakeCaseDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()

public enum CodexAuth {
    /// Reads the ChatGPT login Codex (CLI or the ChatGPT desktop app) saved in `<codex_home>/auth.json`.
    /// Never refreshes it: that rotates the refresh token and would sign Codex out.
    public static func resolve(codexHome: String, now: Date = .now) throws -> CodexCredentials {
        let dir = URL(fileURLWithPath: expandHome(codexHome)).standardizedFileURL.path
        let file = URL(fileURLWithPath: dir).appending(path: "auth.json")
        let login = "run: CODEX_HOME=\(dir) codex login"
        guard let data = try? Data(contentsOf: file) else {
            throw UsageError("no Codex login found in \(dir) (\(login))")
        }
        guard let auth = try? snakeCaseDecoder.decode(CodexAuthFile.self, from: data) else {
            throw UsageError("could not parse \(file.path)")
        }
        guard let token = auth.tokens?.accessToken, !token.isEmpty else {
            throw UsageError("no ChatGPT login in \(file.path) (\(login))")
        }
        let expiresAt = jwtExpiry(token)
        if let expiresAt, expiresAt <= now {
            let when = expiresAt.formatted(date: .abbreviated, time: .shortened)
            throw UsageError("access token expired \(when) (run codex with CODEX_HOME=\(dir) to refresh it)")
        }
        return CodexCredentials(token: token, accountID: auth.tokens?.accountId, source: file.path, expiresAt: expiresAt)
    }
}

public enum CodexClient {
    /// What Codex itself calls for /status. Undocumented, like the Claude endpoint.
    public static let baseURL = URL(string: "https://chatgpt.com/backend-api/wham")!

    public static func fetch(
        _ creds: CodexCredentials, session: URLSession = .shared
    ) async throws -> (usage: CodexUsage, resetCredits: [CodexResetCredit]) {
        let usage: CodexUsage
        do {
            usage = try CodexUsage.decode(try await get("usage", creds, session))
        } catch let error as DecodingError {
            throw UsageError("unexpected usage response: \(error.localizedDescription)")
        }
        // Only the reset expiry dates need this second call, so it's skipped when there are none
        // and a failure just leaves them out.
        guard usage.rateLimitResetCredits?.availableCount ?? 0 > 0,
            let data = try? await get("rate-limit-reset-credits", creds, session),
            let list = try? snakeCaseDecoder.decode(CodexResetCreditList.self, from: data)
        else { return (usage, []) }
        return (usage, list.credits)
    }

    private static func get(_ path: String, _ creds: CodexCredentials, _ session: URLSession) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 10)
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        request.setValue(creds.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UsageError("HTTP \(status): \(UsageClient.errorMessage(data))")
        }
        return data
    }
}
