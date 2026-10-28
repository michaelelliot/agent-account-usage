#!/usr/bin/env bun
import { Command, Option } from "commander";
import { DEFAULT_CONFIG_PATH, expandHome, loadConfig } from "./config";
import { resolveCredentials, type Credentials } from "./credentials";
import { formatError, formatProfile } from "./format";
import { fetchUsage, type Usage } from "./usage";

interface Options {
  config: string;
  profile: string[];
  all?: boolean;
  json?: boolean;
}

type Result = { name: string; label: string } & (
  { creds: Credentials; usage: Usage } | { error: string }
);

const collect = (value: string, previous: string[]) => [...previous, value];

const program = new Command()
  .name("agent-usage")
  .description(
    "Print Claude.ai plan quota usage for accounts in an INI config file",
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
          const creds = await resolveCredentials(section);
          return { name, label, creds, usage: await fetchUsage(creds.token) };
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
          "error" in r ? { error: r.error } : r.usage,
        ]),
      );
      console.log(JSON.stringify(out, null, 2));
    } else {
      const blocks = results.map((r) =>
        "error" in r
          ? formatError(r.label, r.error)
          : formatProfile(r.label, r.creds, r.usage),
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
      const source = section.oauth_token
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
