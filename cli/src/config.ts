import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export type Section = Record<string, string>;
export type Config = Map<string, Section>;

// ~/.config/subsmasher/config, or ~/.config/agent-usage/config, from when this was agent-account-usage,
// while only that exists.
export function defaultConfigPath(home = homedir()): string {
  const path = join(home, ".config", "subsmasher", "config");
  const legacy = join(home, ".config", "agent-usage", "config");
  return existsSync(path) || !existsSync(legacy) ? path : legacy;
}

export function parseIni(text: string): Config {
  const config: Config = new Map();
  let current: Section | undefined;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#") || line.startsWith(";")) continue;
    const header = line.match(/^\[\s*(.+?)\s*\]$/);
    if (header) {
      const name = header[1]!;
      current = config.get(name) ?? {};
      config.set(name, current);
      continue;
    }
    const eq = line.indexOf("=");
    if (eq === -1 || !current) continue;
    const key = line.slice(0, eq).trim();
    if (key) current[key] = unquote(line.slice(eq + 1).trim());
  }
  return config;
}

function unquote(value: string): string {
  const quoted =
    value.length >= 2 &&
    (value[0] === '"' || value[0] === "'") &&
    value.at(-1) === value[0];
  return quoted ? value.slice(1, -1) : value;
}

export async function loadConfig(path: string): Promise<Config> {
  const file = Bun.file(path);
  if (!(await file.exists())) throw new Error(`config file not found: ${path}`);
  return parseIni(await file.text());
}

export function expandHome(path: string): string {
  if (path === "~") return homedir();
  if (path.startsWith("~/")) return join(homedir(), path.slice(2));
  return path;
}
