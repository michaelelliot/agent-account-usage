import { join, resolve } from "node:path";
import { expandHome } from "./config";
import { jwtExpiry } from "./credentials";

// What Codex itself calls for /status. Undocumented, like the Claude endpoint.
export const CODEX_BASE_URL = "https://chatgpt.com/backend-api/wham";

export interface CodexCredentials {
  token: string;
  accountId?: string;
  source: string;
  expiresAt?: number;
}

interface CodexAuthFile {
  tokens?: { access_token?: string; account_id?: string } | null;
}

export interface CodexWindow {
  used_percent: number;
  limit_window_seconds: number;
  // Unix seconds.
  reset_at: number | null;
}

export interface CodexUsage {
  plan_type?: string | null;
  rate_limit?: {
    limit_reached?: boolean;
    primary_window?: CodexWindow | null;
    secondary_window?: CodexWindow | null;
  } | null;
  // Spent once a limit is reached. balance is a decimal string, e.g. "60511.4630200000".
  credits?: {
    has_credits?: boolean;
    unlimited?: boolean;
    balance?: string | null;
  } | null;
  rate_limit_reset_credits?: { available_count?: number } | null;
}

export interface CodexResetCredits {
  credits: { status: string; expires_at: string | null }[];
}

export interface CodexReport {
  usage: CodexUsage;
  reset_credits: CodexResetCredits | null;
}

// Reads the ChatGPT login Codex (CLI or the ChatGPT desktop app) saved in <codex_home>/auth.json.
export async function resolveCodexCredentials(
  codexHome: string,
): Promise<CodexCredentials> {
  const dir = resolve(expandHome(codexHome));
  const file = Bun.file(join(dir, "auth.json"));
  const login = `run: CODEX_HOME=${dir} codex login`;
  if (!(await file.exists()))
    throw new Error(`no Codex login found in ${dir} (${login})`);
  let auth: CodexAuthFile;
  try {
    auth = await file.json();
  } catch {
    throw new Error(`could not parse ${file.name}`);
  }
  const token = auth.tokens?.access_token;
  if (!token) throw new Error(`no ChatGPT login in ${file.name} (${login})`);
  const expiresAt = jwtExpiry(token);
  if (expiresAt && expiresAt <= Date.now()) {
    throw new Error(
      `access token expired ${new Date(expiresAt).toLocaleString()} (run codex with CODEX_HOME=${dir} to refresh it)`,
    );
  }
  return {
    token,
    accountId: auth.tokens?.account_id,
    source: file.name!,
    expiresAt,
  };
}

async function get<T>(path: string, creds: CodexCredentials): Promise<T> {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${creds.token}`,
  };
  if (creds.accountId) headers["ChatGPT-Account-Id"] = creds.accountId;
  const res = await fetch(`${CODEX_BASE_URL}${path}`, {
    headers,
    signal: AbortSignal.timeout(10_000),
  });
  const body = await res.text();
  if (!res.ok) {
    let message = body.slice(0, 200);
    try {
      const detail = JSON.parse(body).detail;
      if (typeof detail === "string") message = detail;
    } catch {}
    throw new Error(`HTTP ${res.status}: ${message}`);
  }
  return JSON.parse(body) as T;
}

export async function fetchCodexUsage(
  creds: CodexCredentials,
): Promise<CodexReport> {
  const usage = await get<CodexUsage>("/usage", creds);
  // Only the reset expiry dates need this second call, so it's skipped when there are none
  // and a failure just leaves them out.
  const reset_credits = usage.rate_limit_reset_credits?.available_count
    ? await get<CodexResetCredits>("/rate-limit-reset-credits", creds).catch(
        () => null,
      )
    : null;
  return { usage, reset_credits };
}
