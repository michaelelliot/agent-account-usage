import { describe, expect, test } from "bun:test";
import { stripVTControlCharacters } from "node:util";
import type { CodexReport } from "./codex";
import {
  bar,
  formatCodexProfile,
  formatDuration,
  formatError,
  formatProfile,
} from "./format";
import type { Usage } from "./usage";

const NOW = Date.parse("2026-10-28T15:30:00Z");
const PLAIN = { now: NOW, color: false };
const creds = { token: "t", source: "test", subscriptionType: "max" };

describe("formatProfile", () => {
  test("renders limits[] rows with reset times and extra usage", () => {
    const usage: Usage = {
      limits: [
        {
          kind: "session",
          percent: 42,
          resets_at: "2026-10-28T17:43:00.384567+00:00",
        },
        {
          kind: "weekly_all",
          percent: 8,
          resets_at: "2026-10-30T06:00:00.384594+00:00",
        },
        {
          kind: "weekly_scoped",
          percent: 0,
          resets_at: null,
          scope: { model: { display_name: "Fable" } },
        },
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
    expect(formatProfile("personal", creds, usage, PLAIN)).toBe(
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
    expect(
      formatProfile(
        "work",
        { token: "t", source: "oauth_token" },
        usage,
        PLAIN,
      ),
    ).toBe(
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
      extra_usage: {
        is_enabled: false,
        monthly_limit: null,
        used_credits: null,
        utilization: null,
      },
    };
    expect(formatProfile("p", creds, usage, PLAIN)).not.toContain(
      "Extra usage",
    );
  });

  test("colours by utilization level and otherwise matches plain output", () => {
    const usage: Usage = {
      limits: [
        { kind: "session", percent: 20, resets_at: null },
        { kind: "weekly_all", percent: 75, resets_at: null },
        {
          kind: "weekly_scoped",
          percent: 95,
          resets_at: "2026-10-28T16:00:00Z",
          scope: { model: { display_name: "Fable" } },
        },
      ],
    };
    const lines = formatProfile("p", creds, usage, {
      now: NOW,
      color: true,
    }).split("\n");
    expect(lines[0]).toBe("\x1b[1m[p]\x1b[22m  \x1b[2mmax\x1b[22m");
    expect(lines[1]).toContain("\x1b[32m 20%");
    expect(lines[2]).toContain("\x1b[33m 75%");
    expect(lines[3]).toContain("\x1b[31m 95%");
    expect(lines[3]).toContain("\x1b[2m  resets in 30m");
    expect(stripVTControlCharacters(lines.join("\n"))).toBe(
      formatProfile("p", creds, usage, PLAIN),
    );
  });

  test("says so when no limits are reported", () => {
    expect(formatProfile("p", creds, {}, PLAIN)).toBe(
      "[p]  max\n  no plan usage limits reported",
    );
  });
});

describe("formatCodexProfile", () => {
  // Trimmed from real /wham/usage and /wham/rate-limit-reset-credits responses.
  const report: CodexReport = {
    usage: {
      plan_type: "pro",
      rate_limit: {
        limit_reached: true,
        primary_window: {
          used_percent: 100,
          limit_window_seconds: 604800,
          reset_at: NOW / 1000 + (11 * 60 + 24) * 60,
        },
        secondary_window: null,
      },
      credits: { has_credits: true, unlimited: false, balance: "60511.46302" },
      rate_limit_reset_credits: { available_count: 3 },
    },
    reset_credits: {
      credits: [
        { status: "redeemed", expires_at: "2026-10-29T00:00:00Z" },
        { status: "available", expires_at: "2026-12-01T22:27:46.796390Z" },
        { status: "available", expires_at: "2026-11-01T19:30:00.660200Z" },
      ],
    },
  };

  test("renders windows, credits in use and the soonest reset expiry", () => {
    expect(formatCodexProfile("ChatGPT", report, PLAIN)).toBe(
      [
        "[ChatGPT]  pro",
        "  Weekly        ████████████████████ 100%  resets in 11h 24m",
        "  Credits       60,511  in use until the limit resets",
        "  Limit resets  3 available  next expires in 4d 4h",
      ].join("\n"),
    );
  });

  test("labels 5-hour windows as the session and hides empty extras", () => {
    const usage: CodexReport["usage"] = {
      plan_type: "plus",
      rate_limit: {
        limit_reached: false,
        primary_window: {
          used_percent: 12,
          limit_window_seconds: 18000,
          reset_at: null,
        },
        secondary_window: {
          used_percent: 40,
          limit_window_seconds: 604800,
          reset_at: null,
        },
      },
      credits: { has_credits: false, unlimited: false, balance: "0" },
      rate_limit_reset_credits: { available_count: 0 },
    };
    expect(formatCodexProfile("p", { usage, reset_credits: null }, PLAIN)).toBe(
      [
        "[p]  plus",
        "  Session (5h)  ██░░░░░░░░░░░░░░░░░░  12%",
        "  Weekly        ████████░░░░░░░░░░░░  40%",
      ].join("\n"),
    );
  });

  test("shows the reset count alone when expiry dates are unavailable", () => {
    expect(
      formatCodexProfile("p", { ...report, reset_credits: null }, PLAIN),
    ).toEndWith("\n  Limit resets  3 available");
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
    expect(formatError("x", "boom", { color: false })).toBe(
      "[x]\n  error: boom",
    );
    expect(formatError("x", "boom", { color: true })).toBe(
      "\x1b[1m[x]\x1b[22m\n  \x1b[31merror:\x1b[39m boom",
    );
  });
});
