import { createHash } from "node:crypto";
import { homedir, userInfo } from "node:os";
import { join, resolve } from "node:path";
import { expandHome, type Section } from "./config";

export interface Credentials {
  token: string;
  source: string;
  subscriptionType?: string;
  expiresAt?: number;
}

interface StoredCredentials {
  claudeAiOauth?: {
    accessToken?: string;
    expiresAt?: number;
    subscriptionType?: string | null;
  };
}

// Mirrors how Claude Code names its keychain item for a given CLAUDE_CONFIG_DIR.
export function keychainServices(configDir: string): string[] {
  const hash = createHash("sha256").update(configDir.normalize("NFC")).digest("hex").slice(0, 8);
  const suffixed = `Claude Code-credentials-${hash}`;
  // With CLAUDE_CONFIG_DIR unset, Claude Code uses ~/.claude and an unsuffixed service name.
  return configDir === join(homedir(), ".claude") ? ["Claude Code-credentials", suffixed] : [suffixed];
}

async function readKeychain(service: string): Promise<string | undefined> {
  if (process.platform !== "darwin") return undefined;
  const account = process.env.USER || userInfo().username;
  const proc = Bun.spawn(["security", "find-generic-password", "-a", account, "-w", "-s", service], {
    stdout: "pipe",
    stderr: "ignore",
  });
  const [out, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  return code === 0 && out.trim() ? out.trim() : undefined;
}

function parseStored(raw: string, source: string): Credentials {
  let data: StoredCredentials;
  try {
    data = JSON.parse(raw);
  } catch {
    throw new Error(`could not parse credentials from ${source}`);
  }
  const oauth = data.claudeAiOauth;
  if (!oauth?.accessToken) throw new Error(`no Claude.ai OAuth token in ${source}`);
  return {
    token: oauth.accessToken,
    source,
    subscriptionType: oauth.subscriptionType ?? undefined,
    expiresAt: oauth.expiresAt,
  };
}

async function readConfigDir(configDir: string): Promise<Credentials | undefined> {
  for (const service of keychainServices(configDir)) {
    const raw = await readKeychain(service);
    if (raw) return parseStored(raw, `keychain "${service}"`);
  }
  const file = Bun.file(join(configDir, ".credentials.json"));
  if (await file.exists()) return parseStored(await file.text(), file.name!);
  return undefined;
}

export async function resolveCredentials(section: Section): Promise<Credentials> {
  if (section.oauth_token) return { token: section.oauth_token, source: "oauth_token" };
  if (!section.claude_config_dir) throw new Error("section needs oauth_token or claude_config_dir");

  const configDir = resolve(expandHome(section.claude_config_dir));
  const creds = await readConfigDir(configDir);
  if (!creds) {
    throw new Error(`no Claude Code login found for ${configDir} (run: CLAUDE_CONFIG_DIR=${configDir} claude /login)`);
  }
  if (creds.expiresAt && creds.expiresAt <= Date.now()) {
    throw new Error(
      `access token expired ${new Date(creds.expiresAt).toLocaleString()} (run claude with CLAUDE_CONFIG_DIR=${configDir} to refresh it)`,
    );
  }
  return creds;
}
