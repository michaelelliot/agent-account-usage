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
    return usage.limits.map((l) => ({ label: limitLabel(l), percent: l.percent, resetsAt: l.resets_at }));
  }
  return LEGACY_WINDOWS.flatMap(([key, label]) => {
    const window = usage[key];
    return window?.utilization != null ? [{ label, percent: window.utilization, resetsAt: window.resets_at }] : [];
  });
}

export function bar(percent: number): string {
  const filled = Math.round((Math.min(Math.max(percent, 0), 100) / 100) * BAR_WIDTH);
  return "█".repeat(filled) + "░".repeat(BAR_WIDTH - filled);
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
  return new Intl.NumberFormat("en-US", { style: "currency", currency }).format(minor / 10 ** decimals);
}

function extraUsageText(extra: ExtraUsage): string | undefined {
  if (!extra.is_enabled && extra.monthly_limit == null) return undefined;
  const decimals = extra.decimal_places ?? 2;
  const currency = extra.currency ?? "USD";
  const used = money(extra.used_credits ?? 0, decimals, currency);
  let text = extra.monthly_limit != null ? `${used} / ${money(extra.monthly_limit, decimals, currency)}` : `${used} used`;
  if (extra.utilization != null) text += ` (${Math.round(extra.utilization)}%)`;
  if (!extra.is_enabled) {
    text += extra.disabled_reason ? `  disabled (${extra.disabled_reason.replaceAll("_", " ")})` : "  disabled";
  }
  return text;
}

export function formatProfile(name: string, creds: Credentials, usage: Usage, now = Date.now()): string {
  const lines = [creds.subscriptionType ? `[${name}]  ${creds.subscriptionType}` : `[${name}]`];
  const rows = usageRows(usage);
  const extra = usage.extra_usage ? extraUsageText(usage.extra_usage) : undefined;
  const labelWidth = Math.max(...rows.map((r) => r.label.length), extra ? "Extra usage".length : 0) + 2;

  if (!rows.length) lines.push("  no plan usage limits reported");
  for (const row of rows) {
    const percent = `${Math.round(row.percent)}%`.padStart(4);
    const reset = row.resetsAt ? `  resets in ${formatDuration(Date.parse(row.resetsAt) - now)}` : "";
    lines.push(`  ${row.label.padEnd(labelWidth)}${bar(row.percent)} ${percent}${reset}`);
  }
  if (extra) lines.push(`  ${"Extra usage".padEnd(labelWidth)}${extra}`);
  return lines.join("\n");
}

export function formatError(name: string, message: string): string {
  return `[${name}]\n  error: ${message}`;
}
