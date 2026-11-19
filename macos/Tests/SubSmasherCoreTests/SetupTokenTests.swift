import Foundation
import Testing

@testable import SubSmasherCore

struct SetupTokenTests {
    static let now = Date(timeIntervalSince1970: 1_783_170_000)
    static let sessionReset = Date(timeIntervalSince1970: 1_783_180_800)
    static let weeklyReset = Date(timeIntervalSince1970: 1_783_713_600)

    // A setup-token probe's headers, as captured in July 2026.
    static let normal = [
        "anthropic-ratelimit-unified-5h-utilization": "0.01",
        "anthropic-ratelimit-unified-5h-reset": "1783180800",
        "anthropic-ratelimit-unified-7d-utilization": "0.63",
        "anthropic-ratelimit-unified-7d-reset": "1783713600",
        "anthropic-ratelimit-unified-5h-status": "allowed",
        "anthropic-ratelimit-unified-representative-claim": "five_hour",
        "content-type": "application/json",
    ]

    // An account on paid extra usage, as captured in June 2026.
    static let overage = [
        "anthropic-ratelimit-unified-status": "allowed",
        "anthropic-ratelimit-unified-reset": "1782864000",
        "anthropic-ratelimit-unified-representative-claim": "overage",
        "anthropic-ratelimit-unified-fallback-percentage": "0.5",
        "anthropic-ratelimit-unified-overage-in-use": "true",
        "anthropic-ratelimit-unified-overage-status": "allowed",
        "anthropic-ratelimit-unified-overage-utilization": "0.0",
        "anthropic-ratelimit-unified-overage-reset": "1782864000",
    ]

    static func outcome(_ status: Int, _ headers: [String: String] = [:], body: String = "")
        -> SetupTokenClient.Outcome
    {
        SetupTokenClient.outcome(status: status, headers: headers, body: Data(body.utf8))
    }

    static func apiError(_ type: String, _ message: String) -> String {
        #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#
    }

    @Test func normalHeadersGiveTheSessionAndAllModelsWeekly() throws {
        let limits = try #require(UnifiedLimits(headers: Self.normal))
        let usage = ProfileUsage(setupToken: limits, now: Self.now)
        #expect(usage.rows == [
            UsageRow(label: "Session (5h)", percent: 1, resetsAt: Self.sessionReset),
            UsageRow(label: "Weekly (all models)", percent: 63, resetsAt: Self.weeklyReset),
        ])
        #expect(usage.status == nil)
        #expect(usage.extraUsage == nil)
        #expect(usage.subscriptionType == nil)
        #expect(limits.headers.count == 6, "keeps the raw unified headers, and only those")
    }

    @Test func headerNamesAreCaseInsensitive() {
        let headers = ["Anthropic-Ratelimit-Unified-5h-Utilization": "0.5"]
        #expect(UnifiedLimits(headers: headers)?.fiveHour?.utilization == 0.5)
    }

    @Test func missingHeadersAreNoDataRatherThanZero() throws {
        #expect(UnifiedLimits(headers: ["content-type": "application/json"]) == nil)
        #expect(Self.outcome(200, body: "{}") == .failed(
            ProbeFailure(UsageError("no anthropic-ratelimit-unified-* headers in the response"))))
        let weeklyOnly = try #require(UnifiedLimits(headers: ["anthropic-ratelimit-unified-7d-utilization": "0.2"]))
        #expect(weeklyOnly.rows(now: Self.now) == [UsageRow(label: "Weekly (all models)", percent: 20, resetsAt: nil)])
    }

    @Test func windowsWhoseResetHasPassedShowAsReset() throws {
        let limits = try #require(UnifiedLimits(headers: Self.normal))
        #expect(limits.rows(now: Self.sessionReset) == [
            UsageRow(label: "Session (5h)", percent: 0, resetsAt: nil),
            UsageRow(label: "Weekly (all models)", percent: 63, resetsAt: Self.weeklyReset),
        ])
    }

    @Test func warningStatusesShowNoStatusButUnknownOnesShowAsReceived() throws {
        func statusText(_ status: String, claim: String? = nil) throws -> String? {
            var headers = ["anthropic-ratelimit-unified-status": status]
            headers["anthropic-ratelimit-unified-representative-claim"] = claim
            return try #require(UnifiedLimits(headers: headers)).statusText
        }
        for status in ["allowed", "allowed_warning", "active", "warning"] {
            #expect(try statusText(status) == nil)
        }
        #expect(try statusText("rejected", claim: "five_hour") == "Limited (session)")
        #expect(try statusText("rate_limited") == "Limited")
        #expect(try statusText("throttled") == "throttled")
    }

    @Test func readsTheHeadersOnALimitedAccounts429() throws {
        let headers = [
            "anthropic-ratelimit-unified-status": "rejected",
            "anthropic-ratelimit-unified-representative-claim": "seven_day",
            "anthropic-ratelimit-unified-5h-utilization": "0.25",
            "anthropic-ratelimit-unified-7d-utilization": "1.5",
            "anthropic-ratelimit-unified-7d-reset": "1783713600",
            "retry-after": "540",
        ]
        guard case let .limits(limits) = Self.outcome(429, headers, body: Self.apiError("rate_limit_error", "limited"))
        else {
            Issue.record("expected limits")
            return
        }
        let usage = ProfileUsage(setupToken: limits, now: Self.now)
        #expect(usage.status == "Limited (weekly)")
        #expect(usage.rows.map(\.percent) == [25, 150], "kept unclamped")
        #expect(limits.retryAfter == 540)
    }

    @Test func fallsBackToTheWindowsOwnStatuses() throws {
        let limits = try #require(
            UnifiedLimits(headers: [
                "anthropic-ratelimit-unified-5h-utilization": "1",
                "anthropic-ratelimit-unified-5h-status": "rejected",
                "anthropic-ratelimit-unified-7d-status": "allowed",
            ]))
        #expect(limits.statusText == "Limited (session)")
        #expect(UnifiedLimits(headers: Self.normal)?.statusText == nil)
    }

    @Test func overageShowsExtraUsageInUseAndNoWindows() throws {
        let limits = try #require(UnifiedLimits(headers: Self.overage))
        let usage = ProfileUsage(setupToken: limits, now: Self.now)
        #expect(usage.rows.isEmpty)
        #expect(usage.extraUsage == ExtraUsageSummary(amount: "In use", percent: 0, isEnabled: true, disabledReason: nil))
        #expect(usage.status == nil)

        var exhausted = Self.overage
        exhausted["anthropic-ratelimit-unified-status"] = "rejected"
        exhausted["anthropic-ratelimit-unified-overage-status"] = "rejected"
        exhausted["anthropic-ratelimit-unified-overage-disabled-reason"] = "out_of_credits"
        let limited = ProfileUsage(setupToken: try #require(UnifiedLimits(headers: exhausted)), now: Self.now)
        #expect(limited.extraUsage?.amount == "Used up")
        exhausted["anthropic-ratelimit-unified-overage-disabled-reason"] = "org_disabled"
        let off = ProfileUsage(setupToken: try #require(UnifiedLimits(headers: exhausted)), now: Self.now)
        #expect(off.extraUsage?.amount == "Off")
        #expect(limited.extraUsage?.isEnabled == false)
        #expect(limited.extraUsage?.disabledReason == "out of credits")
        #expect(limited.status == "Limited (extra usage)")
    }

    @Test func errorsSayWhetherProbingAgainCouldHelp() {
        #expect(Self.outcome(401, body: Self.apiError("authentication_error", "OAuth token has expired.")) == .failed(
            ProbeFailure(
                UsageError(
                    "HTTP 401: OAuth token has expired. "
                        + "(run claude setup-token signed in to this account, and replace setup_token)"),
                stop: true)))
        let scope = "OAuth token does not meet scope requirement user:profile"
        #expect(Self.outcome(403, body: Self.apiError("permission_error", scope)) == .failed(
            ProbeFailure(UsageError("HTTP 403: \(scope)"), stop: true)))
        let claudeCodeOnly =
            "This credential is only authorized for use with Claude Code and cannot be used for other API requests."
        #expect(Self.outcome(400, body: Self.apiError("invalid_request_error", claudeCodeOnly)) == .failed(
            ProbeFailure(UsageError("HTTP 400: \(claudeCodeOnly)"), stop: true)))
        #expect(Self.outcome(429, ["retry-after": "30"], body: Self.apiError("rate_limit_error", "Rate limited")) == .failed(
            ProbeFailure(UsageError("HTTP 429: Rate limited"), retryAfter: 30)))
        #expect(Self.outcome(529, body: Self.apiError("overloaded_error", "Overloaded")) == .failed(
            ProbeFailure(UsageError("HTTP 529: Overloaded"))))
    }

    @Test func unknownOrDisallowedModelsTryTheNextOne() {
        #expect(Self.outcome(404, body: Self.apiError("not_found_error", "model: claude-old")) == .wrongModel(
            UsageError("HTTP 404: model: claude-old")))
        #expect(Self.outcome(400, body: Self.apiError("invalid_request_error", "This model is not available")) == .wrongModel(
            UsageError("HTTP 400: This model is not available")))
    }

    @Test func probeModelOverridesTheModelList() {
        #expect(SetupTokenClient.models(for: Profile(id: "p")) == SetupTokenClient.defaultModels)
        #expect(SetupTokenClient.models(for: Profile(id: "p", values: ["probe_model": " a, b ,"])) == ["a", "b"])
    }

    @Test func probeSendsAOneTokenMessageAndFallsBackToTheNextModel() async throws {
        StubProtocol.responses = [
            (404, [:], Self.apiError("not_found_error", "model: old")),
            (200, Self.normal, "{}"),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let limits = try await SetupTokenClient.probe(
            token: "tok", models: ["old", "new"], session: URLSession(configuration: configuration))
        #expect(limits == UnifiedLimits(headers: Self.normal))

        #expect(StubProtocol.requests.count == 2)
        let request = try #require(StubProtocol.requests.last)
        #expect(request.url == SetupTokenClient.url)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try #require(try JSONSerialization.jsonObject(with: StubProtocol.bodies[1]) as? [String: Any])
        #expect(body["model"] as? String == "new")
        #expect(body["max_tokens"] as? Int == 1)
        #expect(body["system"] == nil)
        #expect(body["stream"] == nil)
    }

    @Test func probesOnlyAsOftenAsTheTriggerAllows() throws {
        let start = Self.now
        var record = ProbeRecord(attemptedAt: .distantPast)
        #expect(record.shouldProbe(.timer, now: start), "never probed")
        record.record(.success(try #require(UnifiedLimits(headers: Self.normal))), at: start)
        #expect(!record.shouldProbe(.timer, now: start + 9 * 60))
        #expect(record.shouldProbe(.timer, now: start + 10 * 60))
        #expect(!record.shouldProbe(.menuOpened, now: start + 59))
        #expect(record.shouldProbe(.menuOpened, now: start + 60))
        #expect(record.shouldProbe(.manual, now: start + 1))
        // Once the 5-hour window has ended, a probe would probably start the next one.
        #expect(!record.shouldProbe(.timer, now: Self.sessionReset))
        #expect(!record.shouldProbe(.menuOpened, now: Self.sessionReset))
        #expect(record.shouldProbe(.manual, now: Self.sessionReset))
    }

    @Test func waitsOutALimitedAccountsRetryAfter() throws {
        var headers = Self.normal
        headers["anthropic-ratelimit-unified-status"] = "rejected"
        headers["retry-after"] = "1800"
        var record = ProbeRecord(attemptedAt: .distantPast)
        record.record(.success(try #require(UnifiedLimits(headers: headers))), at: Self.now)
        #expect(!record.shouldProbe(.menuOpened, now: Self.now + 1799))
        #expect(record.shouldProbe(.menuOpened, now: Self.now + 1800))
    }

    @Test func backsOffAfterFailuresAndStopsWhenRetryingCantHelp() {
        let start = Self.now
        var record = ProbeRecord(attemptedAt: .distantPast)
        record.record(.failure(ProbeFailure(UsageError("HTTP 529: Overloaded"))), at: start)
        #expect(!record.shouldProbe(.timer, now: start + 19 * 60))
        #expect(record.shouldProbe(.timer, now: start + 20 * 60))
        #expect(!record.shouldProbe(.menuOpened, now: start + 119))
        #expect(record.shouldProbe(.menuOpened, now: start + 120))
        record.record(.failure(ProbeFailure(UsageError("HTTP 529: Overloaded"))), at: start)
        record.record(.failure(ProbeFailure(UsageError("HTTP 529: Overloaded"))), at: start)
        #expect(!record.shouldProbe(.timer, now: start + 59 * 60))
        #expect(record.shouldProbe(.timer, now: start + 60 * 60), "backs off at most an hour")

        record.record(.failure(ProbeFailure(UsageError("HTTP 429: Rate limited"), retryAfter: 3 * 3600)), at: start)
        #expect(!record.shouldProbe(.menuOpened, now: start + 3 * 3600 - 1))
        #expect(record.shouldProbe(.menuOpened, now: start + 3 * 3600))

        record.record(.failure(ProbeFailure(UsageError("HTTP 401: expired"), stop: true)), at: start)
        #expect(!record.shouldProbe(.timer, now: start + 86400))
        #expect(!record.shouldProbe(.menuOpened, now: start + 86400))
        #expect(record.shouldProbe(.manual, now: start))
    }

    /// Probes through `SetupTokenProbes` with its own store, so each call is like a relaunch.
    static func probes(
        _ body: (_ usage: (RefreshTrigger, Date, SetupTokenProbes.Probe) async throws -> ProfileUsage) async throws
            -> Void
    ) async throws {
        let store = MemoryStore()
        let token = "sk-ant-oat01-test-token"
        let profile = Profile(id: "p", values: ["setup_token": token])
        try await body { trigger, now, probe in
            try await SetupTokenProbes.usage(
                for: profile, token: token, trigger: trigger, now: now, store: store, probe: probe)
        }
        #expect(!store.values.isEmpty)
        for (key, value) in store.values {
            #expect(!key.contains(token))
            #expect(!String(decoding: value, as: UTF8.self).contains(token), "the token isn't saved")
        }
    }

    @Test func keepsTheLastValuesThroughAFailureThatARetryCouldFix() async throws {
        let limits = try #require(UnifiedLimits(headers: Self.normal))
        let start = Self.now
        try await Self.probes { usage in try await self.keepsTheLastValues(limits: limits, start: start, usage: usage) }
    }

    @Test func aRelaunchDoesntProbeAnAccountWhoseSessionHasEnded() async throws {
        let limits = try #require(UnifiedLimits(headers: Self.normal))
        try await Self.probes { usage in
            _ = try await usage(.timer, Self.now) { _, _ in limits }
            let later = try await usage(.timer, Self.sessionReset + 3600) { _, _ in
                Issue.record("probed after the 5-hour window ended")
                return limits
            }
            #expect(later.rows.first == UsageRow(label: "Session (5h)", percent: 0, resetsAt: nil))
            #expect(later.checkedAt == Self.now)
        }
    }

    func keepsTheLastValues(
        limits: UnifiedLimits, start: Date,
        usage: (RefreshTrigger, Date, SetupTokenProbes.Probe) async throws -> ProfileUsage
    ) async throws {

        let fresh = try await usage(.timer, start) { token, models in
            #expect(token == "sk-ant-oat01-test-token")
            #expect(models == SetupTokenClient.defaultModels)
            return limits
        }
        #expect(fresh.checkedAt == nil)
        #expect(fresh.refreshError == nil)

        let reused = try await usage(.timer, start + 300) { _, _ in
            Issue.record("probed again within 10 minutes")
            return limits
        }
        #expect(reused.rows == fresh.rows)
        #expect(reused.checkedAt == start)

        let stale = try await usage(.manual, start + 400) { _, _ in
            throw ProbeFailure(UsageError("HTTP 529: Overloaded"))
        }
        #expect(stale.rows == fresh.rows)
        #expect(stale.checkedAt == start)
        #expect(stale.refreshError == "HTTP 529: Overloaded")

        await #expect(throws: UsageError("HTTP 401: expired")) {
            try await usage(.manual, start + 500) { _, _ in
                throw ProbeFailure(UsageError("HTTP 401: expired"), stop: true)
            }
        }
        await #expect(throws: UsageError("HTTP 401: expired")) {
            try await usage(.timer, start + 86400) { _, _ in
                Issue.record("probed automatically after a 401")
                return limits
            }
        }
    }
}

final class MemoryStore: ProbeStore, @unchecked Sendable {
    var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value as? Data }
}

/// Answers each request with the next of `responses`, keeping the requests and their bodies.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(status: Int, headers: [String: String], body: String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        Self.bodies.append(Self.body(of: request))
        let (status, headers, body) = Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
