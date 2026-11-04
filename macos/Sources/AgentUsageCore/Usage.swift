import Foundation

public struct UsageWindow: Decodable, Sendable {
    public let utilization: Double?
    public let resetsAt: String?
}

/// Newer, richer form of the windows above; includes per-model weekly limits.
public struct UsageLimit: Decodable, Sendable {
    public struct Scope: Decodable, Sendable {
        public struct Model: Decodable, Sendable {
            public let displayName: String?
        }

        public let model: Model?
    }

    public let kind: String
    public let percent: Double
    public let resetsAt: String?
    public let scope: Scope?
}

/// Money amounts are in minor units (e.g. cents), see `decimalPlaces`.
public struct ExtraUsage: Decodable, Sendable {
    public let isEnabled: Bool?
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let utilization: Double?
    public let currency: String?
    public let decimalPlaces: Int?
    public let disabledReason: String?
}

public struct Usage: Decodable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let sevenDayOauthApps: UsageWindow?
    public let sevenDayOpus: UsageWindow?
    public let sevenDaySonnet: UsageWindow?
    public let extraUsage: ExtraUsage?
    public let limits: [UsageLimit]?

    public static func decode(_ data: Data) throws -> Usage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Usage.self, from: data)
    }
}

public enum UsageClient {
    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func fetch(token: String, session: URLSession = .shared) async throws -> Usage {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UsageError("HTTP \(status): \(errorMessage(data))")
        }
        do {
            return try Usage.decode(data)
        } catch {
            throw UsageError("unexpected usage response: \(error.localizedDescription)")
        }
    }

    /// Anthropic's `{"error": {"message"}}`, ChatGPT's `{"detail"}`, Cursor's `{"message"}`, or the start of the body.
    static func errorMessage(_ data: Data) -> String {
        let body = String(decoding: data.prefix(200), as: UTF8.self)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return body }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return json["detail"] as? String ?? json["message"] as? String ?? body
    }
}

/// One account's usage, from either provider, ready to show.
public struct ProfileUsage: Sendable {
    public let subscriptionType: String?
    public let rows: [UsageRow]
    public let extraUsage: ExtraUsageSummary?
    public let credits: CreditsSummary?
    public let resets: ResetsSummary?
}

public struct ProfileReport: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let result: Result<ProfileUsage, UsageError>
}

/// Fetches every profile in parallel; reports come back in the profiles' order.
public func fetchReports(for profiles: [Profile]) async -> [ProfileReport] {
    await withTaskGroup(of: (Int, ProfileReport).self) { group in
        for (index, profile) in profiles.enumerated() {
            group.addTask { (index, await fetchReport(for: profile)) }
        }
        var reports = [ProfileReport?](repeating: nil, count: profiles.count)
        for await (index, report) in group {
            reports[index] = report
        }
        return reports.compactMap { $0 }
    }
}

func fetchReport(for profile: Profile) async -> ProfileReport {
    let result: Result<ProfileUsage, UsageError>
    do {
        if let codexHome = profile.values["codex_home"], !codexHome.isEmpty {
            let creds = try CodexAuth.resolve(codexHome: codexHome)
            let (usage, resetCredits) = try await CodexClient.fetch(creds)
            result = .success(ProfileUsage(codex: usage, resetCredits: resetCredits))
        } else if let cursorDir = profile.values["cursor_dir"], !cursorDir.isEmpty {
            let token = try GrokAuth.resolve(cursorDir: cursorDir)
            let (usage, bankedResets) = try await GrokClient.fetch(token: token)
            result = .success(ProfileUsage(grok: usage, bankedResets: bankedResets))
        } else {
            let creds = try CredentialStore.resolve(profile)
            let usage = try await UsageClient.fetch(token: creds.token)
            result = .success(ProfileUsage(claude: usage, subscriptionType: creds.subscriptionType))
        }
    } catch let error as UsageError {
        result = .failure(error)
    } catch {
        result = .failure(UsageError(error.localizedDescription))
    }
    return ProfileReport(id: profile.id, displayName: profile.displayName, result: result)
}
