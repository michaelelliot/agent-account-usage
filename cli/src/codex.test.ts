import { describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveCodexCredentials } from "./codex";

// An unsigned JWT; only the payload's exp is read.
function jwt(exp: number): string {
  const part = (o: object) =>
    Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${part({ alg: "none" })}.${part({ exp })}.sig`;
}

async function withAuthFile(
  contents: unknown,
  fn: (dir: string) => Promise<void>,
) {
  const dir = await mkdtemp(join(tmpdir(), "agent-usage-test-"));
  try {
    await writeFile(join(dir, "auth.json"), JSON.stringify(contents));
    await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

describe("resolveCodexCredentials", () => {
  test("reads the ChatGPT token, account and expiry from auth.json", async () => {
    const exp = Math.floor(Date.now() / 1000) + 3600;
    const token = jwt(exp);
    await withAuthFile(
      {
        auth_mode: "chatgpt",
        tokens: { access_token: token, account_id: "acct" },
      },
      async (dir) => {
        expect(await resolveCodexCredentials(`${dir}/`)).toEqual({
          token,
          accountId: "acct",
          source: join(dir, "auth.json"),
          expiresAt: exp * 1000,
        });
      },
    );
  });

  test("rejects an expired access token", async () => {
    const token = jwt(Math.floor(Date.now() / 1000) - 60);
    await withAuthFile({ tokens: { access_token: token } }, async (dir) => {
      await expect(resolveCodexCredentials(dir)).rejects.toThrow(
        "access token expired",
      );
    });
  });

  test("rejects an API key login, which has no plan usage", async () => {
    await withAuthFile(
      { auth_mode: "apikey", OPENAI_API_KEY: "sk-...", tokens: null },
      async (dir) => {
        await expect(resolveCodexCredentials(dir)).rejects.toThrow(
          "no ChatGPT login in",
        );
      },
    );
  });

  test("reports a codex home with no login", async () => {
    await expect(
      resolveCodexCredentials("/nonexistent/agent-usage"),
    ).rejects.toThrow("no Codex login found in /nonexistent/agent-usage");
  });
});
