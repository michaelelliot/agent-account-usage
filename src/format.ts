import { styleText } from "node:util";
import type { Credentials } from "./credentials";
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

export function formatProfile(
  name: string,
  creds: Credentials,
  usage: Usage,
  { now = Date.now(), color }: FormatOptions = {},
): string {
  const paint = painter(color);
  const header = paint("bold", `[${name}]`);
  const lines = [
    creds.subscriptionType
      ? `${header}  ${paint("dim", creds.subscriptionType)}`
      : header,
  ];
  const rows = usageRows(usage);
  const extra = usage.extra_usage
    ? extraUsageText(usage.extra_usage, paint)
    : undefined;
  const labelWidth =
    Math.max(
      ...rows.map((r) => r.label.length),
      extra ? "Extra usage".length : 0,
    ) + 2;

  if (!rows.length)
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
  if (extra) lines.push(`  ${"Extra usage".padEnd(labelWidth)}${extra}`);
  return lines.join("\n");
}

export function formatError(
  name: string,
  message: string,
  { color }: FormatOptions = {},
): string {
  const paint = painter(color);
  return `${paint("bold", `[${name}]`)}\n  ${paint("red", "error:")} ${message}`;
}
