import { describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import {
  claudeConfigDirFor,
  keychainServices,
  planName,
  resolveCredentials,
} from "./credentials";

describe("keychainServices", () => {
  test("suffixes the service with the first 8 hex chars of sha256(config dir)", () => {
    // sha256("/Users/someone/.claude-work") computed with `shasum -a 256`
    expect(keychainServices("/Users/someone/.claude-work")).toEqual([
      "Claude Code-credentials-18cc900a",
    ]);
  });

  test("tries the unsuffixed service first for ~/.claude", () => {
    const services = keychainServices(join(homedir(), ".claude"));
    expect(services[0]).toBe("Claude Code-credentials");
    expect(services[1]).toMatch(/^Claude Code-credentials-[0-9a-f]{8}$/);
  });
});

describe("claudeConfigDirFor", () => {
  test("leaves CLAUDE_CONFIG_DIR unset for the unsuffixed keychain item", () => {
    const creds = {
      token: "t",
      source: "keychain",
      keychainService: "Claude Code-credentials",
    };
    expect(claudeConfigDirFor(creds, "/home/me/.claude")).toBeUndefined();
  });
});

describe("resolveCredentials", () => {
  const writeCredentials = (dir: string, contents: unknown) =>
    writeFile(join(dir, ".credentials.json"), JSON.stringify(contents));

  async function withCredentialsFile(
    contents: unknown,
    fn: (dir: string) => Promise<void>,
  ) {
    const dir = await mkdtemp(join(tmpdir(), "agent-usage-test-"));
    try {
      await writeCredentials(dir, contents);
      await fn(dir);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }

  test("uses oauth_token as-is, even when claude_config_dir is also set", async () => {
    const creds = await resolveCredentials({
      oauth_token: "tok",
      claude_config_dir: "/nowhere",
    });
    expect(creds).toEqual({ token: "tok", source: "oauth_token" });
  });

  test("rejects a section with no credential keys", async () => {
    await expect(resolveCredentials({})).rejects.toThrow(
      "needs setup_token, claude_config_dir, oauth_token, codex_home or cursor_dir",
    );
  });

  test("reads <dir>/.credentials.json when there is no keychain item", async () => {
    const expiresAt = Date.now() + 3_600_000;
    await withCredentialsFile(
      {
        claudeAiOauth: {
          accessToken: "file-tok",
          expiresAt,
          subscriptionType: "pro",
        },
      },
      async (dir) => {
        const creds = await resolveCredentials({
          claude_config_dir: `${dir}/`,
        });
        expect(creds).toMatchObject({
          token: "file-tok",
          subscriptionType: "pro",
          expiresAt,
        });
      },
    );
  });

  test("shows a Max 20x login as Ultra", async () => {
    await withCredentialsFile(
      {
        claudeAiOauth: {
          accessToken: "tok",
          expiresAt: Date.now() + 3_600_000,
          subscriptionType: "max",
          rateLimitTier: "default_claude_max_20x",
        },
      },
      async (dir) => {
        const creds = await resolveCredentials({ claude_config_dir: dir });
        expect(creds.subscriptionType).toBe("ultra");
      },
    );
    expect(planName("max", "default_claude_max_5x")).toBe("max");
    expect(planName("pro", null)).toBe("pro");
    expect(planName("team", "default_claude_max_20x")).toBe("team");
  });

  test("runs claude to refresh an expired token, then reads it again", async () => {
    await withCredentialsFile(
      { claudeAiOauth: { accessToken: "old", expiresAt: Date.now() - 1000 } },
      async (dir) => {
        const calls: [string | undefined, string | undefined][] = [];
        const creds = await resolveCredentials(
          { claude_config_dir: `${dir}/`, claude_path: "/opt/claude" },
          async (configDir, claudePath) => {
            calls.push([configDir, claudePath]);
            await writeCredentials(dir, {
              claudeAiOauth: {
                accessToken: "new",
                expiresAt: Date.now() + 3_600_000,
              },
            });
          },
        );
        expect(calls).toEqual([[dir, "/opt/claude"]]);
        expect(creds.token).toBe("new");
      },
    );
  });

  test("rejects an expired access token that refreshing didn't renew", async () => {
    await withCredentialsFile(
      { claudeAiOauth: { accessToken: "old", expiresAt: Date.now() - 1000 } },
      async (dir) => {
        const error = await resolveCredentials(
          { claude_config_dir: dir },
          async () => {},
        ).catch((e: Error) => e);
        expect(error).toBeInstanceOf(Error);
        expect((error as Error).message).toStartWith("access token expired");
        expect((error as Error).message).toEndWith(
          `(run claude with CLAUDE_CONFIG_DIR=${dir} to refresh it)`,
        );
      },
    );
  });

  test("reports a config dir with no login", async () => {
    await expect(
      resolveCredentials({ claude_config_dir: "/nonexistent/agent-usage" }),
    ).rejects.toThrow(
      "no Claude Code login found for /nonexistent/agent-usage",
    );
  });
});
