import { describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { keychainServices, resolveCredentials } from "./credentials";

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

describe("resolveCredentials", () => {
  async function withCredentialsFile(
    contents: unknown,
    fn: (dir: string) => Promise<void>,
  ) {
    const dir = await mkdtemp(join(tmpdir(), "agent-usage-test-"));
    try {
      await writeFile(join(dir, ".credentials.json"), JSON.stringify(contents));
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
      "needs oauth_token or claude_config_dir",
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

  test("rejects an expired access token", async () => {
    await withCredentialsFile(
      { claudeAiOauth: { accessToken: "old", expiresAt: Date.now() - 1000 } },
      async (dir) => {
        await expect(
          resolveCredentials({ claude_config_dir: dir }),
        ).rejects.toThrow("access token expired");
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
