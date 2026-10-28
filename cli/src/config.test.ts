import { describe, expect, test } from "bun:test";
import { homedir } from "node:os";
import { join } from "node:path";
import { expandHome, parseIni } from "./config";

describe("parseIni", () => {
  test("reads sections and trimmed key/value pairs", () => {
    const config = parseIni(
      "[default]\nclaude_config_dir = ~/.claude\n\n[ work ]\noauth_token=sk-ant-oat01-abc\n",
    );
    expect([...config.keys()]).toEqual(["default", "work"]);
    expect(config.get("default")).toEqual({ claude_config_dir: "~/.claude" });
    expect(config.get("work")).toEqual({ oauth_token: "sk-ant-oat01-abc" });
  });

  test("skips comments, blank lines, lines without '=' and keys before any section", () => {
    const config = parseIni(
      "orphan = 1\n# comment\n; also comment\n[default]\n  # indented comment\nnot a pair\nkey = value\n",
    );
    expect([...config.keys()]).toEqual(["default"]);
    expect(config.get("default")).toEqual({ key: "value" });
  });

  test("keeps '=' inside values and handles CRLF", () => {
    const config = parseIni("[default]\r\ntoken = a=b==\r\n");
    expect(config.get("default")).toEqual({ token: "a=b==" });
  });

  test("merges repeated sections, later keys win", () => {
    const config = parseIni("[a]\nx = 1\ny = 2\n[b]\n[a]\nx = 3\n");
    expect(config.get("a")).toEqual({ x: "3", y: "2" });
  });

  test("strips one pair of matching surrounding quotes", () => {
    const config = parseIni(
      `[default]\na = "me@example.com"\nb = 'single'\nc = "mismatched'\nd = ""\ne = say "hi"\n`,
    );
    expect(config.get("default")).toEqual({
      a: "me@example.com",
      b: "single",
      c: `"mismatched'`,
      d: "",
      e: 'say "hi"',
    });
  });

  test("keeps empty sections", () => {
    expect(parseIni("[empty]\n").get("empty")).toEqual({});
  });
});

describe("expandHome", () => {
  test("expands a leading ~", () => {
    expect(expandHome("~")).toBe(homedir());
    expect(expandHome("~/.claude")).toBe(join(homedir(), ".claude"));
  });

  test("leaves other paths alone", () => {
    expect(expandHome("/tmp/~x")).toBe("/tmp/~x");
    expect(expandHome("~other/x")).toBe("~other/x");
  });
});
