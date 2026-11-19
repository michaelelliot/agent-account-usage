import { Database } from "bun:sqlite";
import { describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { decrypt, resolveGrokToken } from "./grok";

// An unsigned JWT; only the payload's exp is read.
function jwt(exp: number): string {
  const part = (o: object) =>
    Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${part({ alg: "none" })}.${part({ exp })}.sig`;
}

// A Cursor data dir whose state.vscdb holds `token` unencrypted, as Cursor stores it when
// there's no OS keychain.
async function withCursorDir(
  token: string | null,
  fn: (dir: string) => Promise<void>,
) {
  const dir = await mkdtemp(join(tmpdir(), "subsmash-test-"));
  try {
    await mkdir(join(dir, "User", "globalStorage"), { recursive: true });
    const db = new Database(join(dir, "User", "globalStorage", "state.vscdb"));
    db.run(
      "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)",
    );
    if (token)
      db.run("INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', ?)", [
        token,
      ]);
    db.close();
    await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test("decrypt reverses Electron safeStorage encryption", () => {
  // Encrypted with node:crypto the way Electron does on macOS, using password "test-password".
  const stored =
    "cursor-safe-storage:v1:djEwaTKn8QSpJ4aIH7pIsFHxMWdeVpGH4Q7X7hMfDsr+cpE=";
  expect(decrypt(stored, "test-password")).toBe("header.payload.signature");
  expect(() => decrypt(stored, "wrong")).toThrow(
    "could not decrypt Cursor's saved login",
  );
});

describe("resolveGrokToken", () => {
  test("reads Cursor's saved access token", async () => {
    const token = jwt(Math.floor(Date.now() / 1000) + 3600);
    await withCursorDir(token, async (dir) => {
      expect(await resolveGrokToken(`${dir}/`)).toBe(token);
    });
  });

  test("rejects an expired access token", async () => {
    await withCursorDir(
      jwt(Math.floor(Date.now() / 1000) - 60),
      async (dir) => {
        await expect(resolveGrokToken(dir)).rejects.toThrow(
          "access token expired",
        );
      },
    );
  });

  test("reports a signed-out Cursor", async () => {
    await withCursorDir(null, async (dir) => {
      await expect(resolveGrokToken(dir)).rejects.toThrow(
        `no Cursor login found in ${dir}`,
      );
    });
  });

  test("reports a dir with no Cursor data", async () => {
    await expect(resolveGrokToken("/nonexistent/Cursor")).rejects.toThrow(
      "no Cursor data found in /nonexistent/Cursor",
    );
  });
});
