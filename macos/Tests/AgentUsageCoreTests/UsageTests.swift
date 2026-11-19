import Foundation
import Testing

@testable import AgentUsageCore

struct UsageTests {
    // Trimmed from a real /api/oauth/usage response.
    static let response = """
        {
          "five_hour": {"utilization": 42, "resets_at": "2026-10-28T17:43:00.384567+00:00", "limit_dollars": null},
          "seven_day": {"utilization": 8, "resets_at": "2026-10-30T06:00:00.384594+00:00"},
          "seven_day_opus": null,
          "tangelo": null,
          "extra_usage": {
            "is_enabled": false, "monthly_limit": 4000, "used_credits": 2666, "utilization": 66.65,
            "currency": "USD", "decimal_places": 2, "disabled_reason": "out_of_credits", "daily": null
          },
          "limits": [
            {"kind": "session", "group": "session", "percent": 42, "severity": "normal",
             "resets_at": "2026-10-28T17:43:00.384567+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_all", "group": "weekly", "percent": 8, "severity": "normal",
             "resets_at": "2026-10-30T06:00:00.384594+00:00", "scope": null, "is_active": true},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 0, "severity": "normal", "resets_at": null,
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
          ]
        }
        """

    static func date(_ string: String) -> Date {
        try! Date(string, strategy: .iso8601)
    }

    @Test func rowsComeFromLimitsWhenPresent() throws {
        let usage = try Usage.decode(Data(Self.response.utf8))
        #expect(usage.rows == [
            UsageRow(label: "Session (5h)", percent: 42, resetsAt: Self.date("2026-10-28T17:43:00.384567Z")),
            UsageRow(label: "Weekly", percent: 8, resetsAt: Self.date("2026-10-30T06:00:00.384594Z")),
            UsageRow(label: "Weekly Fable", percent: 0, resetsAt: nil),
        ])
    }

    @Test func rowsFallBackToLegacyWindowsSkippingNulls() throws {
        let usage = try Usage.decode(
            Data(
                """
                {"five_hour": {"utilization": 100, "resets_at": "2026-10-28T15:45:00Z"},
                 "seven_day": {"utilization": 55.4, "resets_at": null},
                 "seven_day_opus": null,
                 "seven_day_sonnet": {"utilization": null, "resets_at": null}}
                """.utf8))
        #expect(usage.rows == [
            UsageRow(label: "Session (5h)", percent: 100, resetsAt: Self.date("2026-10-28T15:45:00Z")),
            UsageRow(label: "Weekly", percent: 55.4, resetsAt: nil),
        ])
    }

    @Test func extraUsageSummaryConvertsMinorUnits() throws {
        let usage = try Usage.decode(Data(Self.response.utf8))
        #expect(usage.extraUsage?.summary == ExtraUsageSummary(
            amount: "$26.66 / $40.00", percent: 66.65, isEnabled: false, disabledReason: "out of credits"))
    }

    @Test func extraUsageHiddenWhenOffWithoutLimit() throws {
        let usage = try Usage.decode(
            Data(#"{"extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null}}"#.utf8))
        #expect(usage.extraUsage != nil)
        #expect(usage.extraUsage?.summary == nil)
    }

    @Test func levelsByUtilization() {
        #expect(Level(percent: 69.9) == .normal)
        #expect(Level(percent: 70) == .warning)
        #expect(Level(percent: 90) == .critical)
    }

    @Test func durationPicksTwoLargestUnits() {
        #expect(formatDuration(-1) == "0m")
        #expect(formatDuration(59 * 60) == "59m")
        #expect(formatDuration((2 * 60 + 13) * 60) == "2h 13m")
        #expect(formatDuration((26 * 60 + 30) * 60) == "1d 2h")
    }

    @Test func apiErrorMessageFallsBackToBody() {
        #expect(UsageClient.errorMessage(Data(#"{"error":{"message":"OAuth access token is invalid."}}"#.utf8))
            == "OAuth access token is invalid.")
        #expect(UsageClient.errorMessage(Data("upstream down".utf8)) == "upstream down")
    }

    @Test func orderedFollowsSavedOrderThenAppendsUnknown() {
        let profiles = ["a", "b", "c", "d"].map { Profile(id: $0) }
        #expect(ordered(profiles, by: []).map(\.id) == ["a", "b", "c", "d"])
        #expect(ordered(profiles, by: ["c", "a"]).map(\.id) == ["c", "a", "b", "d"])
        #expect(ordered(profiles, by: ["gone", "d", "c", "b", "a", "d"]).map(\.id) == ["d", "c", "b", "a"])
    }

    @Test func movingTakesTheTargetsPosition() {
        let ids = ["a", "b", "c", "d"]
        #expect(moving("a", to: "c", in: ids) == ["b", "c", "a", "d"])
        #expect(moving("d", to: "b", in: ids) == ["a", "d", "b", "c"])
        #expect(moving("b", to: "b", in: ids) == ids)
        #expect(moving("x", to: "b", in: ids) == ids)
        #expect(moving("a", to: "x", in: ids) == ids)
    }

    @Test func dropIndexSnapsPastEachNeighboursMidpoint() {
        let heights = [60.0, 200, 100]
        #expect(dropIndex(heights: heights, dragging: 0, offset: 0) == 0)
        #expect(dropIndex(heights: heights, dragging: 0, offset: 100) == 0)
        #expect(dropIndex(heights: heights, dragging: 0, offset: 101) == 1)
        #expect(dropIndex(heights: heights, dragging: 0, offset: 251) == 2)
        #expect(dropIndex(heights: heights, dragging: 0, offset: 999) == 2)
        #expect(dropIndex(heights: heights, dragging: 2, offset: -100) == 2)
        #expect(dropIndex(heights: heights, dragging: 2, offset: -101) == 1)
        #expect(dropIndex(heights: heights, dragging: 2, offset: -231) == 0)
        #expect(dropIndex(heights: heights, dragging: 1, offset: -31) == 0)
        #expect(dropIndex(heights: heights, dragging: 1, offset: 51) == 2)
    }

    @Test func slotOffsetIsTheHeightOfTheRowsPassed() {
        let heights = [60.0, 200, 100]
        #expect(slotOffset(heights: heights, from: 0, to: 2) == 300)
        #expect(slotOffset(heights: heights, from: 2, to: 0) == -260)
        #expect(slotOffset(heights: heights, from: 1, to: 2) == 100)
        #expect(slotOffset(heights: heights, from: 1, to: 1) == 0)
    }

    // Hits the real API with your config: AGENT_USAGE_LIVE_TEST=1 swift test
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_USAGE_LIVE_TEST"] != nil))
    func liveReportsForConfiguredProfiles() async throws {
        let profiles = try ConfigFile.load(from: ConfigFile.defaultURL)
        for report in await fetchReports(for: profiles, trigger: .manual) {
            switch report.result {
            case let .success(profile):
                var parts = profile.rows.map { "\($0.label) \(Int($0.percent.rounded()))%" }
                if let credits = profile.credits { parts.append("credits \(credits.balance)") }
                if let resets = profile.resets {
                    parts.append("resets \(resets.available), next expires \(resets.nextExpiry?.description ?? "?")")
                }
                print("[\(report.displayName)] \(profile.subscriptionType ?? "-"): \(parts.joined(separator: ", "))")
            case let .failure(error):
                print("[\(report.displayName)] error: \(error.message)")
            }
        }
    }
}
