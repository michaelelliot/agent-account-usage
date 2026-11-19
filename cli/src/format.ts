import { styleText } from "node:util";
import type { CodexReport, CodexUsage } from "./codex";
import type { Credentials } from "./credentials";
import type { GrokReport, GrokUsage } from "./grok";
import { isLimited, isOverage, type UnifiedLimits } from "./setup-token";
import type { ExtraUsage, Usage, UsageLimit } from "./usage";

const BAR_WIDTH = 20;

const LEGACY_WINDOWS = [
  ["five_hour", "Session (5h)"],
  ["seven_day", "Weekly"],
  ["seven_day_opus", "Weekly Opus"],
  ["seven_day_sonnet", "Weekly Sonnet"],
  ["seven_day_oauth_apps", "Weekly OAuth apps"],
] as const;

type Style = Parameters<typeof styleText>[0];
type Paint = (style: Style, text: string) => string;

export interface FormatOptions {
  now?: number;
  // true forces colour, false disables it, unset follows stdout (TTY, NO_COLOR, FORCE_COLOR).
  color?: boolean;
}

const plain: Paint = (_style, text) => text;

function painter(color?: boolean): Paint {
  if (color === false) return plain;
  return (style, text) =>
    text
      ? styleText(style, text, { validateStream: color === undefined })
      : text;
}

function level(percent: number): Style {
  return percent >= 90 ? "red" : percent >= 70 ? "yellow" : "green";
}

interface Row {
  label: string;
  percent: number;
  resetsAt: string | null;
}

function limitLabel(limit: UsageLimit): string {
  switch (limit.kind) {
    case "session":
      return "Session (5h)";
    case "weekly_all":
      return "Weekly";
    case "weekly_scoped":
      return `Weekly ${limit.scope?.model?.display_name ?? "(scoped)"}`;
    default:
      return limit.kind;
  }
}

function usageRows(usage: Usage): Row[] {
  if (usage.limits?.length) {
    return usage.limits.map((l) => ({
      label: limitLabel(l),
      percent: l.percent,
      resetsAt: l.resets_at,
    }));
  }
  return LEGACY_WINDOWS.flatMap(([key, label]) => {
    const window = usage[key];
    return window?.utilization != null
      ? [{ label, percent: window.utilization, resetsAt: window.resets_at }]
      : [];
  });
}

export function bar(percent: number, paint: Paint = plain): string {
  const filled = Math.round(
    (Math.min(Math.max(percent, 0), 100) / 100) * BAR_WIDTH,
  );
  return (
    paint(level(percent), "█".repeat(filled)) +
    paint("dim", "░".repeat(BAR_WIDTH - filled))
  );
}

export function formatDuration(ms: number): string {
  const minutes = Math.max(0, Math.round(ms / 60_000));
  const days = Math.floor(minutes / 1440);
  const hours = Math.floor((minutes % 1440) / 60);
  if (days) return `${days}d ${hours}h`;
  if (hours) return `${hours}h ${minutes % 60}m`;
  return `${minutes}m`;
}

function money(minor: number, decimals: number, currency: string): string {
  return new Intl.NumberFormat("en-US", { style: "currency", currency }).format(
    minor / 10 ** decimals,
  );
}

function extraUsageText(extra: ExtraUsage, paint: Paint): string | undefined {
  if (!extra.is_enabled && extra.monthly_limit == null) return undefined;
  const decimals = extra.decimal_places ?? 2;
  const currency = extra.currency ?? "USD";
  const used = money(extra.used_credits ?? 0, decimals, currency);
  let text =
    extra.monthly_limit != null
      ? `${used} / ${money(extra.monthly_limit, decimals, currency)}`
      : `${used} used`;
  if (extra.utilization != null)
    text += ` ${paint(level(extra.utilization), `(${Math.round(extra.utilization)}%)`)}`;
  if (!extra.is_enabled) {
    text += paint(
      "dim",
      extra.disabled_reason
        ? `  disabled (${extra.disabled_reason.replaceAll("_", " ")})`
        : "  disabled",
    );
  }
  return text;
}

function renderProfile(
  paint: Paint,
  name: string,
  plan: string | null | undefined,
  rows: Row[],
  details: [label: string, text: string][],
  now: number,
): string {
  const header = paint("bold", `[${name}]`);
  const lines = [plan ? `${header}  ${paint("dim", plan)}` : header];
  const labels = [...rows.map((r) => r.label), ...details.map(([l]) => l)];
  const labelWidth = Math.max(...labels.map((l) => l.length)) + 2;

  if (!rows.length && !details.length)
    lines.push(`  ${paint("dim", "no plan usage limits reported")}`);
  for (const row of rows) {
    const percent = paint(
      level(row.percent),
      `${Math.round(row.percent)}%`.padStart(4),
    );
    const reset = row.resetsAt
      ? paint(
          "dim",
          `  resets in ${formatDuration(Date.parse(row.resetsAt) - now)}`,
        )
      : "";
    lines.push(
      `  ${row.label.padEnd(labelWidth)}${bar(row.percent, paint)} ${percent}${reset}`,
    );
  }
  for (const [label, text] of details)
    lines.push(`  ${label.padEnd(labelWidth)}${text}`);
  return lines.join("\n");
}

export function formatProfile(
  name: string,
  creds: Credentials,
  usage: Usage,
  { now = Date.now(), color }: FormatOptions = {},
): string {
  const paint = painter(color);
  const extra = usage.extra_usage
    ? extraUsageText(usage.extra_usage, paint)
    : undefined;
  return renderProfile(
    paint,
    name,
    creds.subscriptionType,
    usageRows(usage),
    extra ? [["Extra usage", extra]] : [],
    now,
  );
}

function windowLabel(seconds: number): string {
  const hours = Math.round(seconds / 3600);
  if (hours === 168) return "Weekly";
  return hours < 24 ? `Session (${hours}h)` : `${Math.round(hours / 24)}-day`;
}

function codexRows(usage: CodexUsage): Row[] {
  const limit = usage.rate_limit;
  return [limit?.primary_window, limit?.secondary_window].flatMap((w) =>
    w
      ? [
          {
            label: windowLabel(w.limit_window_seconds),
            percent: w.used_percent,
            resetsAt:
              w.reset_at != null
                ? new Date(w.reset_at * 1000).toISOString()
                : null,
          },
        ]
      : [],
  );
}

function creditsText(usage: CodexUsage, paint: Paint): string | undefined {
  const credits = usage.credits;
  if (credits?.unlimited) return "unlimited";
  const balance = Number(credits?.balance ?? 0);
  if (!(balance > 0)) return undefined;
  const text = balance.toLocaleString("en-US", { maximumFractionDigits: 0 });
  // With the plan limit reached, Codex keeps working by spending credits.
  return usage.rate_limit?.limit_reached
    ? text + paint("dim", "  in use until the limit resets")
    : text;
}

// Available full resets of the usage limits, and when the soonest one expires.
function resetsText(
  count: number,
  expiries: number[],
  now: number,
  paint: Paint,
): string | undefined {
  if (!count) return undefined;
  const next = expiries.length
    ? paint(
        "dim",
        `  next expires in ${formatDuration(Math.min(...expiries) - now)}`,
      )
    : "";
  return `${count} available${next}`;
}

export function formatCodexProfile(
  name: string,
  report: CodexReport,
  { now = Date.now(), color }: FormatOptions = {},
): string {
  const paint = painter(color);
  const details: [string, string][] = [];
  const credits = creditsText(report.usage, paint);
  if (credits) details.push(["Credits", credits]);
  const expiries = (report.reset_credits?.credits ?? []).flatMap((c) =>
    c.status === "available" && c.expires_at ? [Date.parse(c.expires_at)] : [],
  );
  const resets = resetsText(
    report.usage.rate_limit_reset_credits?.available_count ?? 0,
    expiries,
    now,
    paint,
  );
  if (resets) details.push(["Limit resets", resets]);
  return renderProfile(
    paint,
    name,
    report.usage.plan_type,
    codexRows(report.usage),
    details,
    now,
  );
}

function grokRows(usage: GrokUsage): Row[] {
  // Grok Bot shows nothing for these either.
  if (usage.usagePercent == null || usage.usesPooledEnterpriseAllowance)
    return [];
  const start = Date.parse(usage.currentPeriodStart ?? "");
  const end = Date.parse(usage.nextResetTimestampUtc ?? "");
  return [
    {
      label: end > start ? windowLabel((end - start) / 1000) : "Weekly",
      percent: usage.usagePercent,
      resetsAt: usage.nextResetTimestampUtc ?? null,
    },
  ];
}

export function formatGrokProfile(
  name: string,
  { usage, banked_resets }: GrokReport,
  { now = Date.now(), color }: FormatOptions = {},
): string {
  const paint = painter(color);
  // A unified Cursor and Grok account is on a Cursor plan.
  const plan = usage.isUnified
    ? usage.cursorPlanName || usage.grokPlanLabel
    : usage.grokPlanLabel || usage.cursorPlanName;
  const expiries = (banked_resets?.resets ?? []).flatMap((r) =>
    r.expiresAt ? [Date.parse(r.expiresAt)] : [],
  );
  const resets = resetsText(
    Number(usage.availableBankedResetCount ?? 0),
    expiries,
    now,
    paint,
  );
  return renderProfile(
    paint,
    name,
    plan,
    grokRows(usage),
    resets ? [["Limit resets", resets]] : [],
    now,
  );
}

// A window whose reset time has passed has rolled over, so shows as unused. The weekly limit is the
// one across all models: the headers don't carry the per-model ones, which often run out first.
function setupTokenRows(limits: UnifiedLimits, now: number): Row[] {
  const windows = [
    ["Session (5h)", limits.five_hour],
    ["Weekly (all models)", limits.seven_day],
  ] as const;
  return windows.flatMap(([label, window]) => {
    if (window?.utilization == null) return [];
    const resetsAt = window.reset != null ? window.reset * 1000 : null;
    if (resetsAt != null && resetsAt <= now)
      return [{ label, percent: 0, resetsAt: null }];
    return [
      {
        label,
        percent: window.utilization * 100,
        resetsAt: resetsAt != null ? new Date(resetsAt).toISOString() : null,
      },
    ];
  });
}

// "Limited (weekly)" when a limit binds, or a status this doesn't know, as received. Some
// responses only carry the windows' own statuses.
function setupTokenStatus(limits: UnifiedLimits): string | undefined {
  const limitedWindow = isLimited(limits.five_hour?.status ?? null)
    ? "five_hour"
    : isLimited(limits.seven_day?.status ?? null)
      ? "seven_day"
      : undefined;
  const status = limits.status ?? (limitedWindow ? "rejected" : undefined);
  if (
    !status ||
    ["allowed", "allowed_warning", "active", "warning"].includes(status)
  )
    return undefined;
  if (!isLimited(status)) return status;
  const window = {
    five_hour: "session",
    seven_day: "weekly",
    overage: "extra usage",
  }[limits.representative_claim ?? limitedWindow ?? ""];
  return window ? `Limited (${window})` : "Limited";
}

// The reset that comes with extra usage is the billing period's, weeks away, so it isn't shown.
function overageText(limits: UnifiedLimits, paint: Paint): string {
  let text = !isLimited(limits.overage_status)
    ? "In use"
    : limits.overage_disabled_reason === "out_of_credits"
      ? "Used up"
      : "Off";
  if (limits.overage_utilization != null) {
    const percent = limits.overage_utilization * 100;
    text += ` ${paint(level(percent), `(${Math.round(percent)}%)`)}`;
  }
  if (isLimited(limits.overage_status)) {
    const reason = limits.overage_disabled_reason?.replaceAll("_", " ");
    text += paint("dim", reason ? `  disabled (${reason})` : "  disabled");
  }
  return text;
}

export function formatSetupTokenProfile(
  name: string,
  limits: UnifiedLimits,
  { now = Date.now(), color }: FormatOptions = {},
): string {
  const paint = painter(color);
  const details: [string, string][] = [];
  if (isOverage(limits))
    details.push(["Extra usage", overageText(limits, paint)]);
  const status = setupTokenStatus(limits);
  if (status) details.push(["Status", paint("red", status)]);
  return renderProfile(
    paint,
    name,
    undefined,
    setupTokenRows(limits, now),
    details,
    now,
  );
}

export function formatError(
  name: string,
  message: string,
  { color }: FormatOptions = {},
): string {
  const paint = painter(color);
  return `${paint("bold", `[${name}]`)}\n  ${paint("red", "error:")} ${message}`;
}
