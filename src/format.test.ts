import { describe, expect, test } from "bun:test";
import { bar, formatDuration, formatError, formatProfile } from "./format";
import type { Usage } from "./usage";

const NOW = Date.parse("2026-10-28T15:30:00Z");
const creds = { token: "t", source: "test", subscriptionType: "max" };

describe("formatProfile", () => {
  test("renders limits[] rows with reset times and extra usage", () => {
    const usage: Usage = {
      limits: [
        { kind: "session", percent: 42, resets_at: "2026-10-28T17:43:00.384567+00:00" },
        { kind: "weekly_all", percent: 8, resets_at: "2026-10-30T06:00:00.384594+00:00" },
        { kind: "weekly_scoped", percent: 0, resets_at: null, scope: { model: { display_name: "Fable" } } },
      ],
      extra_usage: {
        is_enabled: false,
        monthly_limit: 4000,
        used_credits: 2666,
        utilization: 66.65,
        currency: "USD",
        decimal_places: 2,
        disabled_reason: "out_of_credits",
      },
    };
    expect(formatProfile("personal", creds, usage, NOW)).toBe(
      [
        "[personal]  max",
        "  Session (5h)  ████████░░░░░░░░░░░░  42%  resets in 2h 13m",
        "  Weekly        ██░░░░░░░░░░░░░░░░░░   8%  resets in 1d 14h",
        "  Weekly Fable  ░░░░░░░░░░░░░░░░░░░░   0%",
        "  Extra usage   $26.66 / $40.00 (67%)  disabled (out of credits)",
      ].join("\n"),
    );
  });

  test("falls back to legacy windows and skips null ones", () => {
    const usage: Usage = {
      five_hour: { utilization: 100, resets_at: "2026-10-28T15:45:00Z" },
      seven_day: { utilization: 55.4, resets_at: null },
      seven_day_opus: null,
      seven_day_sonnet: { utilization: null, resets_at: null },
    };
    expect(formatProfile("work", { token: "t", source: "oauth_token" }, usage, NOW)).toBe(
      [
        "[work]",
        "  Session (5h)  ████████████████████ 100%  resets in 15m",
        "  Weekly        ███████████░░░░░░░░░  55%",
      ].join("\n"),
    );
  });

  test("hides extra usage when it is off and has no limit", () => {
    const usage: Usage = {
      limits: [{ kind: "weekly_all", percent: 1, resets_at: null }],
      extra_usage: { is_enabled: false, monthly_limit: null, used_credits: null, utilization: null },
    };
    expect(formatProfile("p", creds, usage, NOW)).not.toContain("Extra usage");
  });

  test("says so when no limits are reported", () => {
    expect(formatProfile("p", creds, {}, NOW)).toBe("[p]  max\n  no plan usage limits reported");
  });
});

describe("helpers", () => {
  test("bar clamps and scales to 20 cells", () => {
    expect(bar(-5)).toBe("░".repeat(20));
    expect(bar(50)).toBe("█".repeat(10) + "░".repeat(10));
    expect(bar(150)).toBe("█".repeat(20));
  });

  test("formatDuration picks the two largest units", () => {
    expect(formatDuration(-1000)).toBe("0m");
    expect(formatDuration(59 * 60_000)).toBe("59m");
    expect(formatDuration((2 * 60 + 13) * 60_000)).toBe("2h 13m");
    expect(formatDuration((26 * 60 + 30) * 60_000)).toBe("1d 2h");
  });

  test("formatError", () => {
    expect(formatError("x", "boom")).toBe("[x]\n  error: boom");
  });
});
