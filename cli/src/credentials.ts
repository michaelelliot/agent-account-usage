import { createHash } from "node:crypto";
import { homedir, tmpdir, userInfo } from "node:os";
import { dirname, join, resolve } from "node:path";
import { expandHome, type Section } from "./config";

export interface Credentials {
  token: string;
  source: string;
  subscriptionType?: string;
  expiresAt?: number;
  // The keychain item the token was read from, if it came from the keychain.
  keychainService?: string;
}

interface StoredCredentials {
  claudeAiOauth?: {
    accessToken?: string;
    expiresAt?: number;
    subscriptionType?: string | null;
  };
}

// The exp claim of a JWT access token, in ms.
export function jwtExpiry(token: string): number | undefined {
  try {
    const payload = JSON.parse(
      Buffer.from(token.split(".")[1]!, "base64url").toString(),
    );
    return typeof payload.exp === "number" ? payload.exp * 1000 : undefined;
  } catch {
    return undefined;
  }
}

const DEFAULT_SERVICE = "Claude Code-credentials";

// Mirrors how Claude Code names its keychain item for a given CLAUDE_CONFIG_DIR.
export function keychainServices(configDir: string): string[] {
  const hash = createHash("sha256")
    .update(configDir.normalize("NFC"))
    .digest("hex")
    .slice(0, 8);
  const suffixed = `${DEFAULT_SERVICE}-${hash}`;
  // With CLAUDE_CONFIG_DIR unset, Claude Code uses ~/.claude and an unsuffixed service name.
  return configDir === join(homedir(), ".claude")
    ? [DEFAULT_SERVICE, suffixed]
    : [suffixed];
}

// What to set CLAUDE_CONFIG_DIR to when running claude for these credentials. Claude Code only uses
// the unsuffixed keychain item when CLAUDE_CONFIG_DIR is unset, even if it's set to ~/.claude.
export function claudeConfigDirFor(
  creds: Credentials,
  configDir: string,
): string | undefined {
  return creds.keychainService === DEFAULT_SERVICE ? undefined : configDir;
}

export async function readKeychain(
  service: string,
  account = process.env.USER || userInfo().username,
): Promise<string | undefined> {
  if (process.platform !== "darwin") return undefined;
  const proc = Bun.spawn(
    ["security", "find-generic-password", "-a", account, "-w", "-s", service],
    {
      stdout: "pipe",
      stderr: "ignore",
    },
  );
  const [out, code] = await Promise.all([
    new Response(proc.stdout).text(),
    proc.exited,
  ]);
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
  if (!oauth?.accessToken)
    throw new Error(`no Claude.ai OAuth token in ${source}`);
  return {
    token: oauth.accessToken,
    source,
    subscriptionType: oauth.subscriptionType ?? undefined,
    expiresAt: oauth.expiresAt,
  };
}

async function readConfigDir(
  configDir: string,
): Promise<Credentials | undefined> {
  for (const service of keychainServices(configDir)) {
    const raw = await readKeychain(service);
    if (raw)
      return {
        ...parseStored(raw, `keychain "${service}"`),
        keychainService: service,
      };
  }
  const file = Bun.file(join(configDir, ".credentials.json"));
  if (await file.exists()) return parseStored(await file.text(), file.name!);
  return undefined;
}

// Where Claude Code's installers put `claude`, for when it isn't on PATH.
const CLAUDE_INSTALL_DIRS = [
  join(homedir(), ".local", "bin"),
  join(homedir(), ".claude", "local"),
  "/opt/homebrew/bin",
  "/usr/local/bin",
];

// Always an absolute path, so the child's PATH never gets a relative entry.
function findClaude(claudePath?: string): string | null {
  const searchPath = [process.env.PATH, ...CLAUDE_INSTALL_DIRS]
    .filter(Boolean)
    .join(":");
  return Bun.which(claudePath ? expandHome(claudePath) : "claude", {
    PATH: searchPath,
  });
}

// Runs Claude Code's /cost command, which makes it refresh an expired access token and save the
// new one itself. /cost runs locally, so the model isn't called. Project settings and MCP servers
// in the working directory are skipped, as it isn't one we control.
async function refreshWithClaude(
  configDir: string | undefined,
  claudePath?: string,
): Promise<void> {
  const claude = findClaude(claudePath);
  if (!claude) return;
  // An npm-installed claude runs under node, which is usually next to it but may not be on PATH.
  const env: Record<string, string | undefined> = {
    ...process.env,
    PATH: [dirname(claude), process.env.PATH].filter(Boolean).join(":"),
  };
  if (configDir) env.CLAUDE_CONFIG_DIR = configDir;
  else delete env.CLAUDE_CONFIG_DIR;
  try {
    const proc = Bun.spawn(
      [
        claude,
        "-p",
        "/cost",
        "--no-session-persistence",
        "--setting-sources",
        "user",
        "--strict-mcp-config",
      ],
      {
        cwd: tmpdir(),
        env,
        stdin: "ignore",
        stdout: "ignore",
        stderr: "ignore",
        timeout: 60_000,
      },
    );
    await proc.exited;
  } catch {}
}

export async function resolveCredentials(
  section: Section,
  refresh: typeof refreshWithClaude = refreshWithClaude,
): Promise<Credentials> {
  if (section.oauth_token)
    return { token: section.oauth_token, source: "oauth_token" };
  if (!section.claude_config_dir)
    throw new Error(
      "section needs setup_token, claude_config_dir, oauth_token, codex_home or cursor_dir",
    );

  const configDir = resolve(expandHome(section.claude_config_dir));
  let creds = await readConfigDir(configDir);
  if (!creds) {
    throw new Error(
      `no Claude Code login found for ${configDir} (run: CLAUDE_CONFIG_DIR=${configDir} claude /login)`,
    );
  }
  const claudeConfigDir = claudeConfigDirFor(creds, configDir);
  if (creds.expiresAt && creds.expiresAt <= Date.now()) {
    await refresh(claudeConfigDir, section.claude_path);
    creds = (await readConfigDir(configDir)) ?? creds;
  }
  if (creds.expiresAt && creds.expiresAt <= Date.now()) {
    const command = claudeConfigDir
      ? `claude with CLAUDE_CONFIG_DIR=${claudeConfigDir}`
      : "claude";
    throw new Error(
      `access token expired ${new Date(creds.expiresAt).toLocaleString()} (run ${command} to refresh it)`,
    );
  }
  return creds;
}
