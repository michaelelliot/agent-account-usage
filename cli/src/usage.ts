export const USAGE_URL = "https://api.anthropic.com/api/oauth/usage";

export interface UsageWindow {
  utilization: number | null;
  resets_at: string | null;
}

// Newer, richer form of the windows above; includes per-model weekly limits.
export interface UsageLimit {
  kind: string;
  group?: string;
  percent: number;
  severity?: string;
  resets_at: string | null;
  scope?: { model?: { display_name?: string | null } | null } | null;
}

// Money amounts are in minor units (e.g. cents), see decimal_places.
export interface ExtraUsage {
  is_enabled: boolean;
  monthly_limit: number | null;
  used_credits: number | null;
  utilization: number | null;
  currency?: string | null;
  decimal_places?: number | null;
  disabled_reason?: string | null;
}

export interface Usage {
  five_hour?: UsageWindow | null;
  seven_day?: UsageWindow | null;
  seven_day_oauth_apps?: UsageWindow | null;
  seven_day_opus?: UsageWindow | null;
  seven_day_sonnet?: UsageWindow | null;
  extra_usage?: ExtraUsage | null;
  limits?: UsageLimit[];
}

export async function fetchUsage(token: string): Promise<Usage> {
  const res = await fetch(USAGE_URL, {
    headers: {
      Authorization: `Bearer ${token}`,
      "anthropic-beta": "oauth-2025-04-20",
    },
    signal: AbortSignal.timeout(10_000),
  });
  const body = await res.text();
  if (!res.ok) {
    let message = body.slice(0, 200);
    try {
      message = JSON.parse(body).error?.message ?? message;
    } catch {}
    throw new Error(`HTTP ${res.status}: ${message}`);
  }
  return JSON.parse(body) as Usage;
}
