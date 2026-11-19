// Prints `agent-usage -a` output for sample accounts, in colour, for the README's screenshot. Run
// macos/scripts/screenshots.sh rather than this directly.
import {
  formatCodexProfile,
  formatGrokProfile,
  formatProfile,
  formatSetupTokenProfile,
} from "../src/format";
import { parseUnifiedHeaders } from "../src/setup-token";

const now = Date.now();
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const at = (fromNow: number) => new Date(now + fromNow).toISOString();
const unix = (fromNow: number) => String(Math.round((now + fromNow) / 1000));
const options = { now, color: true };

const claude = formatProfile(
  "me@example.com",
  { token: "", source: "sample", subscriptionType: "max" },
  {
    limits: [
      { kind: "session", percent: 42, resets_at: at(2 * HOUR + 13 * MINUTE) },
      { kind: "weekly_all", percent: 82, resets_at: at(DAY + 8 * HOUR) },
      {
        kind: "weekly_scoped",
        percent: 30,
        resets_at: at(DAY + 8 * HOUR),
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
  },
  options,
);

const setupToken = formatSetupTokenProfile(
  "Work",
  parseUnifiedHeaders({
    "anthropic-ratelimit-unified-5h-utilization": "0.07",
    "anthropic-ratelimit-unified-5h-reset": unix(4 * HOUR + 31 * MINUTE),
    "anthropic-ratelimit-unified-7d-utilization": "0.91",
    "anthropic-ratelimit-unified-7d-reset": unix(2 * DAY + 5 * HOUR),
  })!,
  options,
);

const chatgpt = formatCodexProfile(
  "ChatGPT",
  {
    usage: {
      plan_type: "pro",
      rate_limit: {
        limit_reached: false,
        primary_window: {
          used_percent: 64,
          limit_window_seconds: 7 * 24 * 3600,
          reset_at: (now + 5 * DAY + 22 * HOUR) / 1000,
        },
        secondary_window: null,
      },
      credits: { has_credits: true, unlimited: false, balance: "59945.2" },
      rate_limit_reset_credits: { available_count: 3 },
    },
    reset_credits: {
      credits: [{ status: "available", expires_at: at(11 * DAY + 9 * HOUR) }],
    },
  },
  options,
);

const grok = formatGrokProfile(
  "Grok",
  {
    usage: {
      currentPeriodStart: at(2 * DAY + 18 * HOUR - 7 * DAY),
      nextResetTimestampUtc: at(2 * DAY + 18 * HOUR),
      usagePercent: 32,
      grokPlanLabel: "Grok Bot Plan",
      cursorPlanName: "Ultra",
      isUnified: true,
    },
    banked_resets: null,
  },
  options,
);

console.log([claude, setupToken, chatgpt, grok].join("\n\n"));
