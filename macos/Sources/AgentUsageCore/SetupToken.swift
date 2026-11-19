import CryptoKit
import Foundation

/// Plan usage from the `anthropic-ratelimit-unified-*` headers of a `POST /v1/messages` response. A `claude
/// setup-token` token only has the `user:inference` scope, so `/api/oauth/usage` (which needs `user:profile`)
/// refuses it, but it can send a message, and the response carries these. They're undocumented and each one is
/// optional: a missing header means no data, not 0.
public struct UnifiedLimits: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        /// Share of the window used, from 0 to 1. Can go above 1.
        public let utilization: Double?
        public let resetsAt: Date?
        public let status: String?
    }

    public let fiveHour: Window?
    public let sevenDay: Window?
    /// Overall status: `allowed`, `allowed_warning` and `rejected`, or `active`, `warning` and `rate_limited`.
    public let status: String?
    /// The window that binds now: `five_hour`, `seven_day` or `overage`.
    public let representativeClaim: String?
    public let overageInUse: Bool
    public let overageStatus: String?
    /// Share of extra usage used, from 0 to 1.
    public let overageUtilization: Double?
    public let overageDisabledReason: String?
    /// How long a limited account's 429 says to wait.
    public let retryAfter: TimeInterval?
    /// The unified headers and `retry-after` as received, keyed by lowercased name. Saved to read them again later.
    public let headers: [String: String]

    static let headerPrefix = "anthropic-ratelimit-unified-"

    /// Nil when there are no unified headers at all.
    public init?(headers: [String: String]) {
        var kept: [String: String] = [:]
        for (name, value) in headers {
            let name = name.lowercased()
            if name.hasPrefix(Self.headerPrefix) || name == "retry-after" {
                kept[name] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        guard kept.keys.contains(where: { $0.hasPrefix(Self.headerPrefix) }) else { return nil }
        func value(_ name: String) -> String? { kept[Self.headerPrefix + name] }
        func number(_ name: String) -> Double? { value(name).flatMap(Double.init) }
        func window(_ name: String) -> Window? {
            let window = Window(
                utilization: number("\(name)-utilization"),
                resetsAt: number("\(name)-reset").map(Date.init(timeIntervalSince1970:)),
                status: value("\(name)-status"))
            return window == Window(utilization: nil, resetsAt: nil, status: nil) ? nil : window
        }
        fiveHour = window("5h")
        sevenDay = window("7d")
        status = value("status")
        representativeClaim = value("representative-claim")
        overageInUse = value("overage-in-use") == "true"
        overageStatus = value("overage-status")
        overageUtilization = number("overage-utilization")
        overageDisabledReason = value("overage-disabled-reason")
        retryAfter = kept["retry-after"].flatMap(TimeInterval.init)
        self.headers = kept
    }

    /// Running on paid extra usage, having used up the plan's. The headers then carry no windows.
    public var isOverage: Bool { overageInUse || representativeClaim == "overage" }

    static func isLimited(_ status: String?) -> Bool {
        status == "rejected" || status == "rate_limited"
    }
}

/// Saved as the headers it was read from.
extension UnifiedLimits: Codable {
    public init(from decoder: Decoder) throws {
        let headers = try decoder.singleValueContainer().decode([String: String].self)
        guard let limits = UnifiedLimits(headers: headers) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no unified headers"))
        }
        self = limits
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(headers)
    }
}

/// A probe that failed, and whether automatic probes should try again.
struct ProbeFailure: Error, Equatable, Codable {
    let error: UsageError
    /// Trying again can't help, as with an expired token or a request the server refuses, so only a manual refresh
    /// probes again.
    let stop: Bool
    /// From a 429's `retry-after`.
    let retryAfter: TimeInterval?

    init(_ error: UsageError, stop: Bool = false, retryAfter: TimeInterval? = nil) {
        self.error = error
        self.stop = stop
        self.retryAfter = retryAfter
    }
}

/// Reads a setup-token account's usage by sending it a one-token message.
public enum SetupTokenClient {
    public static let url = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Cheapest first. A model the plan lacks, or one that's been retired, falls through to the next.
    public static let defaultModels = ["claude-haiku-4-5-20251001", "claude-haiku-5-5"]

    /// The profile's comma-separated `probe_model` list, or the default one.
    static func models(for profile: Profile) -> [String] {
        let configured = (profile.values["probe_model"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return configured.isEmpty ? defaultModels : configured
    }

    /// Sends a one-character prompt with `max_tokens: 1`, which spends a few tokens of the plan, and reads the
    /// headers. Only the OAuth beta header is added: nothing imitates Claude Code.
    public static func probe(
        token: String, models: [String] = defaultModels, session: URLSession = .shared
    ) async throws -> UnifiedLimits {
        var lastModelError = ProbeFailure(UsageError("no probe_model to try"), stop: true)
        for model in models {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "max_tokens": 1, "messages": [["role": "user", "content": "."]],
            ])
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw ProbeFailure(UsageError(error.localizedDescription))
            }
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (name, value) in http?.allHeaderFields ?? [:] {
                if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
            }
            switch outcome(status: http?.statusCode ?? 0, headers: headers, body: data) {
            case let .limits(limits): return limits
            case let .wrongModel(error):
                lastModelError = ProbeFailure(UsageError("\(model): \(error.message)"), stop: true)
            case let .failed(failure): throw failure
            }
        }
        throw lastModelError
    }

    enum Outcome: Equatable {
        case limits(UnifiedLimits)
        /// The plan doesn't include the model, or it was retired: try the next one.
        case wrongModel(UsageError)
        case failed(ProbeFailure)
    }

    /// What a probe's response means. The headers are read on a 429 too, as an account at its limit still gets them.
    static func outcome(status: Int, headers: [String: String], body: Data) -> Outcome {
        if (200..<300).contains(status) || status == 429, let limits = UnifiedLimits(headers: headers) {
            return .limits(limits)
        }
        let message = UsageClient.errorMessage(body)
        let error = UsageError("HTTP \(status): \(message)")
        switch status {
        case 200..<300:
            return .failed(ProbeFailure(UsageError("no \(UnifiedLimits.headerPrefix)* headers in the response")))
        case 401:
            let hint = "run claude setup-token signed in to this account, and replace setup_token"
            return .failed(ProbeFailure(UsageError("\(error.message) (\(hint))"), stop: true))
        case 404:
            return .wrongModel(error)
        case 400 where message.localizedCaseInsensitiveContains("model"):
            return .wrongModel(error)
        case 400, 403:
            // Includes "This credential is only authorized for use with Claude Code". Getting past that would mean
            // imitating Claude Code, which can get the account banned.
            return .failed(ProbeFailure(error, stop: true))
        case 429:
            return .failed(ProbeFailure(error, retryAfter: headers["retry-after"].flatMap(TimeInterval.init)))
        default:
            return .failed(ProbeFailure(error))
        }
    }
}

/// The last probe of one setup-token account.
struct ProbeRecord: Sendable, Codable {
    static let timerInterval: TimeInterval = 10 * 60
    static let menuInterval: TimeInterval = 60
    static let maxBackoff: TimeInterval = 60 * 60

    var attemptedAt: Date
    /// The last limits read, and when.
    var limits: UnifiedLimits?
    var checkedAt: Date?
    /// The last attempt's failure, nil if it succeeded.
    var failure: ProbeFailure?
    var failures = 0

    func shouldProbe(_ trigger: RefreshTrigger, now: Date) -> Bool {
        if trigger == .manual { return true }
        if failure?.stop == true { return false }
        if let retryAfter = failure?.retryAfter, now < attemptedAt.addingTimeInterval(retryAfter) { return false }
        if let retryAfter = limits?.retryAfter, let checkedAt, now < checkedAt.addingTimeInterval(retryAfter) {
            return false
        }
        // The 5-hour window has ended, and probing now would probably start the next one.
        if let reset = limits?.fiveHour?.resetsAt, reset <= now { return false }
        let interval = trigger == .menuOpened ? Self.menuInterval : Self.timerInterval
        let wait = min(interval * pow(2, Double(failures)), Self.maxBackoff)
        return now.timeIntervalSince(attemptedAt) >= wait
    }

    mutating func record(_ result: Result<UnifiedLimits, ProbeFailure>, at now: Date) {
        attemptedAt = now
        switch result {
        case let .success(limits):
            self.limits = limits
            checkedAt = now
            failure = nil
            failures = 0
        case let .failure(failure):
            self.failure = failure
            failures += 1
        }
    }

    /// The last limits read, as of `now`, with their age once it's a minute or more. After a failure that a retry
    /// could fix they're kept, marked with it.
    func usage(now: Date) throws -> ProfileUsage {
        if let failure, failure.stop || limits == nil { throw failure.error }
        guard let limits, let checkedAt else { throw UsageError("not checked yet") }
        var usage = ProfileUsage(setupToken: limits, now: now)
        if now.timeIntervalSince(checkedAt) >= 60 { usage.checkedAt = checkedAt }
        usage.refreshError = failure?.error.message
        return usage
    }
}

/// Where probe records are kept between refreshes and launches.
protocol ProbeStore {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: ProbeStore {}

/// Probes setup-token accounts no more often than each refresh's trigger allows, reusing the last result otherwise.
/// Results are kept in user defaults, so a relaunch doesn't probe an account whose 5-hour window has ended.
enum SetupTokenProbes {
    typealias Probe = @Sendable (_ token: String, _ models: [String]) async throws -> UnifiedLimits

    static func usage(
        for profile: Profile, token: String, trigger: RefreshTrigger, now: Date = .now,
        store: ProbeStore = UserDefaults.standard,
        probe: Probe = { try await SetupTokenClient.probe(token: $0, models: $1) }
    ) async throws -> ProfileUsage {
        let models = SetupTokenClient.models(for: profile)
        // Hashed so the token isn't saved. A changed token or model list starts afresh.
        let digest = SHA256.hash(data: Data(([profile.id, token] + models).joined(separator: "\n").utf8))
        let key = "setupTokenProbe." + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        var record =
            store.data(forKey: key).flatMap { try? JSONDecoder().decode(ProbeRecord.self, from: $0) }
            ?? ProbeRecord(attemptedAt: .distantPast)
        if record.shouldProbe(trigger, now: now) {
            do {
                record.record(.success(try await probe(token, models)), at: now)
            } catch let failure as ProbeFailure {
                record.record(.failure(failure), at: now)
            } catch {
                record.record(.failure(ProbeFailure(UsageError(error.localizedDescription))), at: now)
            }
            store.set(try? JSONEncoder().encode(record), forKey: key)
        }
        return try record.usage(now: now)
    }
}
