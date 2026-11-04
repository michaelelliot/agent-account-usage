import { Database } from "bun:sqlite";
import { createDecipheriv, pbkdf2Sync } from "node:crypto";
import { join, resolve } from "node:path";
import { expandHome } from "./config";
import { jwtExpiry, readKeychain } from "./credentials";

// Grok Bot is a Cursor app and signs in with a Cursor account, so its usage comes from Cursor's
// API. These are the calls Grok Bot makes for its weekly usage. Undocumented, like the others.
export const CURSOR_API_URL =
  "https://api2.cursor.sh/aiserver.v1.DashboardService";

// Cursor encrypts its tokens with Electron safeStorage: "v10" + AES-128-CBC, keyed by
// PBKDF2(the "Cursor Safe Storage" keychain password, "saltysalt", 1003 rounds).
const ENCRYPTED_PREFIX = "cursor-safe-storage:v1:";

export interface GrokUsage {
  currentPeriodStart?: string;
  nextResetTimestampUtc?: string;
  usagePercent?: number;
  // int64, so a string in JSON.
  availableBankedResetCount?: string | number;
  usesPooledEnterpriseAllowance?: boolean;
  grokPlanLabel?: string;
  cursorPlanName?: string;
  isUnified?: boolean;
}

export interface GrokBankedResets {
  resets?: { expiresAt?: string }[];
}

export interface GrokReport {
  usage: GrokUsage;
  banked_resets: GrokBankedResets | null;
}

export function decrypt(stored: string, password: string): string {
  const key = pbkdf2Sync(password, "saltysalt", 1003, 16, "sha1");
  const blob = Buffer.from(stored.slice(ENCRYPTED_PREFIX.length), "base64");
  const decipher = createDecipheriv("aes-128-cbc", key, Buffer.alloc(16, " "));
  try {
    return Buffer.concat([
      decipher.update(blob.subarray(3)),
      decipher.final(),
    ]).toString();
  } catch {
    throw new Error("could not decrypt Cursor's saved login");
  }
}

// Reads the token Cursor saved for its signed-in account. Never refreshes it.
export async function resolveGrokToken(cursorDir: string): Promise<string> {
  const dir = resolve(expandHome(cursorDir));
  const path = join(dir, "User", "globalStorage", "state.vscdb");
  let stored: string | undefined;
  try {
    const db = new Database(path, { readonly: true });
    try {
      db.exec("PRAGMA busy_timeout = 2000");
      stored = (
        db
          .query("SELECT value FROM ItemTable WHERE key = ?")
          .get("cursorAuth/accessToken") as { value: string } | null
      )?.value;
    } finally {
      db.close();
    }
  } catch {
    throw new Error(`no Cursor data found in ${dir}`);
  }
  if (!stored)
    throw new Error(`no Cursor login found in ${dir} (sign in to Cursor)`);
  let token = stored;
  if (stored.startsWith(ENCRYPTED_PREFIX)) {
    const password = await readKeychain("Cursor Safe Storage", "Cursor Key");
    if (!password)
      throw new Error(
        'could not read the "Cursor Safe Storage" key from the keychain (allow access when macOS asks)',
      );
    token = decrypt(stored, password);
  }
  const expiresAt = jwtExpiry(token);
  if (expiresAt && expiresAt <= Date.now()) {
    throw new Error(
      `access token expired ${new Date(expiresAt).toLocaleString()} (open Cursor to refresh it)`,
    );
  }
  return token;
}

async function call<T>(method: string, token: string): Promise<T> {
  const res = await fetch(`${CURSOR_API_URL}/${method}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "Connect-Protocol-Version": "1",
    },
    body: "{}",
    signal: AbortSignal.timeout(10_000),
  });
  const body = await res.text();
  if (!res.ok) {
    let message = body.slice(0, 200);
    try {
      message = JSON.parse(body).message ?? message;
    } catch {}
    throw new Error(`HTTP ${res.status}: ${message}`);
  }
  return JSON.parse(body) as T;
}

export async function fetchGrokUsage(token: string): Promise<GrokReport> {
  const usage = await call<GrokUsage>("GetSandUsageStatus", token);
  // Only the reset expiry dates need this second call, so it's skipped when there are none
  // and a failure just leaves them out.
  const banked_resets =
    Number(usage.availableBankedResetCount ?? 0) > 0
      ? await call<GrokBankedResets>("ListSandBankedResets", token).catch(
          () => null,
        )
      : null;
  return { usage, banked_resets };
}
