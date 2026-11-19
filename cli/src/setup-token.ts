// Usage for a `claude setup-token` token. It only has the user:inference scope, so /api/oauth/usage
// (which needs user:profile) refuses it, but it can send a message, and the response's
// anthropic-ratelimit-unified-* headers carry the plan's limits. They're undocumented and each one is
// optional: a missing header means no data, not 0.
export const MESSAGES_URL = "https://api.anthropic.com/v1/messages";

// Cheapest first. A model the plan lacks, or one that's been retired, falls through to the next.
export const PROBE_MODELS = ["claude-haiku-4-5-20251001", "claude-haiku-5-5"];

const PREFIX = "anthropic-ratelimit-unified-";

// What --json prints: the probe's unified headers as received, keyed by lowercased name.
export interface ProbeReport {
  model: string;
  status: number;
  headers: Record<string, string>;
}

export interface UnifiedWindow {
  // Share of the window used, from 0 to 1. Can go above 1.
  utilization: number | null;
  // Unix seconds.
  reset: number | null;
  status: string | null;
}

export interface UnifiedLimits {
  five_hour: UnifiedWindow | null;
  seven_day: UnifiedWindow | null;
  // allowed, allowed_warning and rejected, or active, warning and rate_limited.
  status: string | null;
  // The window that binds now: five_hour, seven_day or overage.
  representative_claim: string | null;
  overage_in_use: boolean;
  overage_status: string | null;
  // Share of extra usage used, from 0 to 1.
  overage_utilization: number | null;
  overage_disabled_reason: string | null;
}

export function unifiedHeaders(
  headers: Headers | Record<string, string>,
): Record<string, string> {
  const entries =
    headers instanceof Headers ? [...headers] : Object.entries(headers);
  return Object.fromEntries(
    entries.flatMap(([name, value]) =>
      name.toLowerCase().startsWith(PREFIX)
        ? [[name.toLowerCase(), value.trim()]]
        : [],
    ),
  );
}

// Undefined when there are no unified headers at all.
export function parseUnifiedHeaders(
  headers: Record<string, string>,
): UnifiedLimits | undefined {
  const unified = unifiedHeaders(headers);
  if (!Object.keys(unified).length) return undefined;
  const value = (name: string) => unified[PREFIX + name] ?? null;
  const number = (name: string) => {
    const n = Number.parseFloat(value(name) ?? "");
    return Number.isFinite(n) ? n : null;
  };
  const window = (name: string): UnifiedWindow | null => {
    const utilization = number(`${name}-utilization`);
    const reset = number(`${name}-reset`);
    const status = value(`${name}-status`);
    return utilization == null && reset == null && status == null
      ? null
      : { utilization, reset, status };
  };
  return {
    five_hour: window("5h"),
    seven_day: window("7d"),
    status: value("status"),
    representative_claim: value("representative-claim"),
    overage_in_use: value("overage-in-use") === "true",
    overage_status: value("overage-status"),
    overage_utilization: number("overage-utilization"),
    overage_disabled_reason: value("overage-disabled-reason"),
  };
}

// Running on paid extra usage, having used up the plan's. The headers then carry no windows.
export function isOverage(limits: UnifiedLimits): boolean {
  return limits.overage_in_use || limits.representative_claim === "overage";
}

export function isLimited(status: string | null): boolean {
  return status === "rejected" || status === "rate_limited";
}

export type ProbeOutcome =
  | { kind: "limits"; limits: UnifiedLimits }
  // The plan doesn't include the model, or it was retired: try the next one.
  | { kind: "wrong_model"; error: string }
  | { kind: "failed"; error: string };

function apiErrorMessage(body: string): string {
  try {
    const message = JSON.parse(body).error?.message;
    if (typeof message === "string") return message;
  } catch {}
  return body.slice(0, 200);
}

// What a probe's response means. The headers are read on a 429 too, as an account at its limit
// still gets them.
export function probeOutcome(
  status: number,
  headers: Record<string, string>,
  body: string,
): ProbeOutcome {
  const ok = status >= 200 && status < 300;
  const limits = parseUnifiedHeaders(headers);
  if ((ok || status === 429) && limits) return { kind: "limits", limits };
  if (ok)
    return {
      kind: "failed",
      error: `no ${PREFIX}* headers in the response`,
    };
  const message = apiErrorMessage(body);
  const error = `HTTP ${status}: ${message}`;
  if (status === 401)
    return {
      kind: "failed",
      error: `${error} (run claude setup-token signed in to this account, and replace setup_token)`,
    };
  if (status === 404 || (status === 400 && /model/i.test(message)))
    return { kind: "wrong_model", error };
  // Includes 400 "This credential is only authorized for use with Claude Code". Getting past that
  // would mean imitating Claude Code, which can get the account banned.
  return { kind: "failed", error };
}

// The comma-separated probe_model list, or the default one.
export function probeModels(probeModel?: string): string[] {
  const models = (probeModel ?? "")
    .split(",")
    .map((m) => m.trim())
    .filter(Boolean);
  return models.length ? models : PROBE_MODELS;
}

// Sends a one-character prompt with max_tokens 1, which spends a few tokens of the plan, and keeps
// the headers. Only the OAuth beta header is added: nothing imitates Claude Code.
export async function probeUsage(
  token: string,
  models: string[] = PROBE_MODELS,
): Promise<{ report: ProbeReport; limits: UnifiedLimits }> {
  let error = "no probe_model to try";
  for (const model of models) {
    const res = await fetch(MESSAGES_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "oauth-2025-04-20",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model,
        max_tokens: 1,
        messages: [{ role: "user", content: "." }],
      }),
      signal: AbortSignal.timeout(15_000),
    });
    const headers = unifiedHeaders(res.headers);
    const outcome = probeOutcome(res.status, headers, await res.text());
    if (outcome.kind === "limits")
      return {
        report: { model, status: res.status, headers },
        limits: outcome.limits,
      };
    if (outcome.kind === "failed") throw new Error(outcome.error);
    error = `${model}: ${outcome.error}`;
  }
  throw new Error(error);
}
