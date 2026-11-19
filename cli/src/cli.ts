#!/usr/bin/env bun
import { Command, Option } from "commander";
import { fetchCodexUsage, resolveCodexCredentials } from "./codex";
import {
  DEFAULT_CONFIG_PATH,
  expandHome,
  loadConfig,
  type Section,
} from "./config";
import { resolveCredentials } from "./credentials";
import {
  formatCodexProfile,
  formatError,
  formatGrokProfile,
  formatProfile,
  formatSetupTokenProfile,
} from "./format";
import { fetchGrokUsage, resolveGrokToken } from "./grok";
import { probeModels, probeUsage } from "./setup-token";
import { fetchUsage } from "./usage";

interface Options {
  config: string;
  profile: string[];
  all?: boolean;
  json?: boolean;
}

type Report = { json: unknown; text: string };
type Result = { name: string; label: string } & (Report | { error: string });

const collect = (value: string, previous: string[]) => [...previous, value];

async function report(section: Section, label: string): Promise<Report> {
  if (section.codex_home) {
    const codex = await fetchCodexUsage(
      await resolveCodexCredentials(section.codex_home),
    );
    return { json: codex, text: formatCodexProfile(label, codex) };
  }
  if (section.cursor_dir) {
    const grok = await fetchGrokUsage(
      await resolveGrokToken(section.cursor_dir),
    );
    return { json: grok, text: formatGrokProfile(label, grok) };
  }
  if (section.setup_token) {
    const { report, limits } = await probeUsage(
      section.setup_token,
      probeModels(section.probe_model),
    );
    return { json: report, text: formatSetupTokenProfile(label, limits) };
  }
  const creds = await resolveCredentials(section);
  const usage = await fetchUsage(creds.token);
  return { json: usage, text: formatProfile(label, creds, usage) };
}

const program = new Command()
  .name("agent-usage")
  .description(
    "Print Claude, ChatGPT (Codex) and Grok plan quota usage for accounts in an INI config file",
  )
  .option(
    "-c, --config <path>",
    "config file",
    process.env.AGENT_USAGE_CONFIG ?? DEFAULT_CONFIG_PATH,
  )
  .addOption(
    new Option("-p, --profile <name>", "profile to show, repeatable")
      .argParser(collect)
      .default([], '$AGENT_USAGE_PROFILE or "default"'),
  )
  .option("-a, --all", "show every profile in the config file")
  .option("--json", "print raw API responses as JSON keyed by profile")
  .action(async (opts: Options) => {
    const configPath = expandHome(opts.config);
    const config = await loadConfig(configPath);
    const names = opts.all
      ? [...config.keys()]
      : opts.profile.length
        ? opts.profile
        : [process.env.AGENT_USAGE_PROFILE || "default"];

    const results: Result[] = await Promise.all(
      names.map(async (name) => {
        const section = config.get(name);
        const label = section?.name || name;
        try {
          if (!section)
            throw new Error(`no [${name}] section in ${configPath}`);
          return { name, label, ...(await report(section, label)) };
        } catch (e) {
          return {
            name,
            label,
            error: e instanceof Error ? e.message : String(e),
          };
        }
      }),
    );

    if (opts.json) {
      const out = Object.fromEntries(
        results.map((r) => [
          r.name,
          "error" in r ? { error: r.error } : r.json,
        ]),
      );
      console.log(JSON.stringify(out, null, 2));
    } else {
      const blocks = results.map((r) =>
        "error" in r ? formatError(r.label, r.error) : r.text,
      );
      console.log(blocks.join("\n\n"));
    }
    if (results.some((r) => "error" in r)) process.exitCode = 1;
  });

program
  .command("list")
  .description("list profiles in the config file")
  .action(async () => {
    const config = await loadConfig(expandHome(program.opts<Options>().config));
    const width = Math.max(0, ...[...config.keys()].map((name) => name.length));
    for (const [name, section] of config) {
      const source = section.codex_home
        ? `codex_home = ${section.codex_home}`
        : section.cursor_dir
          ? `cursor_dir = ${section.cursor_dir}`
          : section.setup_token
            ? "setup_token"
            : section.oauth_token
              ? "oauth_token"
              : section.claude_config_dir
                ? `claude_config_dir = ${section.claude_config_dir}`
                : "(no credentials)";
      console.log(`${name.padEnd(width)}  ${source}`);
    }
  });

try {
  await program.parseAsync();
} catch (e) {
  program.error(`error: ${e instanceof Error ? e.message : String(e)}`);
}
