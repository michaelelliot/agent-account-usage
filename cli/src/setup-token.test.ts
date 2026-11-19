import { afterEach, describe, expect, spyOn, test } from "bun:test";
import { formatSetupTokenProfile } from "./format";
import {
  MESSAGES_URL,
  PROBE_MODELS,
  parseUnifiedHeaders,
  probeModels,
  probeOutcome,
  probeUsage,
} from "./setup-token";

// A setup-token probe's headers, as captured in July 2026.
const NORMAL = {
  "anthropic-ratelimit-unified-5h-utilization": "0.01",
  "anthropic-ratelimit-unified-5h-reset": "1783180800",
  "anthropic-ratelimit-unified-7d-utilization": "0.63",
  "anthropic-ratelimit-unified-7d-reset": "1783713600",
  "anthropic-ratelimit-unified-5h-status": "allowed",
  "anthropic-ratelimit-unified-representative-claim": "five_hour",
};

// An account on paid extra usage, as captured in June 2026.
const OVERAGE = {
  "anthropic-ratelimit-unified-status": "allowed",
  "anthropic-ratelimit-unified-reset": "1782864000",
  "anthropic-ratelimit-unified-representative-claim": "overage",
  "anthropic-ratelimit-unified-fallback-percentage": "0.5",
  "anthropic-ratelimit-unified-overage-in-use": "true",
  "anthropic-ratelimit-unified-overage-status": "allowed",
  "anthropic-ratelimit-unified-overage-utilization": "0.0",
  "anthropic-ratelimit-unified-overage-reset": "1782864000",
};

const apiError = (type: string, message: string) =>
  JSON.stringify({ type: "error", error: { type, message } });

describe("parseUnifiedHeaders", () => {
  test("reads the windows, ignoring other headers and header case", () => {
    expect(
      parseUnifiedHeaders({
        ...NORMAL,
        "Anthropic-Ratelimit-Unified-Status": "allowed",
        "content-type": "application/json",
      }),
    ).toEqual({
      five_hour: { utilization: 0.01, reset: 1783180800, status: "allowed" },
      seven_day: { utilization: 0.63, reset: 1783713600, status: null },
      status: "allowed",
      representative_claim: "five_hour",
      overage_in_use: false,
      overage_status: null,
      overage_utilization: null,
      overage_disabled_reason: null,
    });
  });

  test("reads extra usage, with no windows", () => {
    expect(parseUnifiedHeaders(OVERAGE)).toMatchObject({
      five_hour: null,
      seven_day: null,
      overage_in_use: true,
      overage_utilization: 0,
    });
  });

  test("is undefined with no unified headers", () => {
    expect(
      parseUnifiedHeaders({ "content-type": "application/json" }),
    ).toBeUndefined();
  });
});

describe("probeOutcome", () => {
  test("reads the headers on a 200, and on a limited account's 429", () => {
    expect(probeOutcome(200, NORMAL, "{}").kind).toBe("limits");
    expect(
      probeOutcome(
        429,
        {
          "anthropic-ratelimit-unified-status": "rejected",
          "anthropic-ratelimit-unified-7d-utilization": "1",
        },
        apiError("rate_limit_error", "limited"),
      ).kind,
    ).toBe("limits");
  });

  test("fails, rather than showing zeros, when the headers are missing", () => {
    expect(probeOutcome(200, {}, "{}")).toEqual({
      kind: "failed",
      error: "no anthropic-ratelimit-unified-* headers in the response",
    });
  });

  test("says how to replace an expired token", () => {
    expect(
      probeOutcome(
        401,
        {},
        apiError("authentication_error", "OAuth token has expired."),
      ),
    ).toEqual({
      kind: "failed",
      error:
        "HTTP 401: OAuth token has expired. (run claude setup-token signed in to this account, and replace setup_token)",
    });
  });

  test("shows scope and Claude Code-only errors as they are", () => {
    const scope = "OAuth token does not meet scope requirement user:profile";
    expect(probeOutcome(403, {}, apiError("permission_error", scope))).toEqual({
      kind: "failed",
      error: `HTTP 403: ${scope}`,
    });
    const claudeCodeOnly =
      "This credential is only authorized for use with Claude Code and cannot be used for other API requests.";
    expect(
      probeOutcome(400, {}, apiError("invalid_request_error", claudeCodeOnly)),
    ).toEqual({ kind: "failed", error: `HTTP 400: ${claudeCodeOnly}` });
  });

  test("moves on from an unknown or disallowed model", () => {
    expect(
      probeOutcome(404, {}, apiError("not_found_error", "model: claude-old")),
    ).toEqual({ kind: "wrong_model", error: "HTTP 404: model: claude-old" });
    expect(
      probeOutcome(
        400,
        {},
        apiError("invalid_request_error", "This model is not available"),
      ).kind,
    ).toBe("wrong_model");
  });
});

describe("probeModels", () => {
  test("probe_model overrides the default list", () => {
    expect(probeModels()).toEqual(PROBE_MODELS);
    expect(probeModels(" a, b ,")).toEqual(["a", "b"]);
  });
});

describe("probeUsage", () => {
  afterEach(() => {
    (
      globalThis.fetch as unknown as { mockRestore?: () => void }
    ).mockRestore?.();
  });

  test("sends a one-token message and falls back to the next model", async () => {
    const requests: [string, RequestInit][] = [];
    const responses = [
      new Response(apiError("not_found_error", "model: old"), { status: 404 }),
      new Response("{}", {
        status: 200,
        headers: { ...NORMAL, "content-type": "application/json" },
      }),
    ];
    spyOn(globalThis, "fetch").mockImplementation((async (
      url: string,
      init: RequestInit,
    ) => {
      requests.push([url, init]);
      return responses.shift()!;
    }) as unknown as typeof fetch);

    const { report, limits } = await probeUsage("tok", ["old", "new"]);
    expect(report).toEqual({ model: "new", status: 200, headers: NORMAL });
    expect(limits.seven_day).toEqual({
      utilization: 0.63,
      reset: 1783713600,
      status: null,
    });

    expect(requests.map(([url]) => url)).toEqual([MESSAGES_URL, MESSAGES_URL]);
    const [, init] = requests[1]!;
    expect(init.method).toBe("POST");
    expect(init.headers).toEqual({
      Authorization: "Bearer tok",
      "anthropic-version": "2023-06-01",
      "anthropic-beta": "oauth-2025-04-20",
      "content-type": "application/json",
    });
    expect(JSON.parse(init.body as string)).toEqual({
      model: "new",
      max_tokens: 1,
      messages: [{ role: "user", content: "." }],
    });
  });

  test("stops at the first failure that isn't about the model", async () => {
    let calls = 0;
    spyOn(globalThis, "fetch").mockImplementation((async () => {
      calls++;
      return new Response(
        apiError("authentication_error", "OAuth token has expired."),
        { status: 401 },
      );
    }) as unknown as typeof fetch);
    await expect(probeUsage("tok", ["a", "b"])).rejects.toThrow(
      "HTTP 401: OAuth token has expired.",
    );
    expect(calls).toBe(1);
  });

  test("reports the last model error when no model works", async () => {
    spyOn(globalThis, "fetch").mockImplementation(
      (async () =>
        new Response(apiError("not_found_error", "model: x"), {
          status: 404,
        })) as unknown as typeof fetch,
    );
    await expect(probeUsage("tok", ["a", "b"])).rejects.toThrow(
      "b: HTTP 404: model: x",
    );
  });
});

describe("formatSetupTokenProfile", () => {
  // Three hours before NORMAL's 5-hour reset.
  const PROBED = 1783170000 * 1000;
  const limits = (headers: Record<string, string>) =>
    parseUnifiedHeaders(headers)!;

  test("renders the session and the weekly limit across all models", () => {
    expect(
      formatSetupTokenProfile("work", limits(NORMAL), {
        now: PROBED,
        color: false,
      }),
    ).toBe(
      [
        "[work]",
        "  Session (5h)         ░░░░░░░░░░░░░░░░░░░░   1%  resets in 3h 0m",
        "  Weekly (all models)  █████████████░░░░░░░  63%  resets in 6d 7h",
      ].join("\n"),
    );
  });

  test("shows a window whose reset has passed as reset", () => {
    expect(
      formatSetupTokenProfile("work", limits(NORMAL), {
        now: 1783180800 * 1000,
        color: false,
      }),
    ).toContain("  Session (5h)         ░░░░░░░░░░░░░░░░░░░░   0%\n");
  });

  test("shows extra usage in use instead of empty windows", () => {
    expect(
      formatSetupTokenProfile("work", limits(OVERAGE), {
        now: PROBED,
        color: false,
      }),
    ).toBe(["[work]", "  Extra usage  In use (0%)"].join("\n"));
  });

  test("shows which limit binds when limited", () => {
    const exhausted = {
      ...OVERAGE,
      "anthropic-ratelimit-unified-status": "rejected",
      "anthropic-ratelimit-unified-overage-status": "rejected",
      "anthropic-ratelimit-unified-overage-disabled-reason": "out_of_credits",
    };
    expect(
      formatSetupTokenProfile("work", limits(exhausted), {
        now: PROBED,
        color: false,
      }),
    ).toEndWith(
      [
        "  Extra usage  Used up (0%)  disabled (out of credits)",
        "  Status       Limited (extra usage)",
      ].join("\n"),
    );
    const off = {
      ...exhausted,
      "anthropic-ratelimit-unified-overage-disabled-reason": "org_disabled",
    };
    expect(
      formatSetupTokenProfile("work", limits(off), {
        now: PROBED,
        color: false,
      }),
    ).toContain("  Extra usage  Off (0%)  disabled (org disabled)\n");
    const weekly = limits({
      "anthropic-ratelimit-unified-status": "rate_limited",
      "anthropic-ratelimit-unified-representative-claim": "seven_day",
      "anthropic-ratelimit-unified-7d-utilization": "1.2",
    });
    expect(
      formatSetupTokenProfile("work", weekly, { now: PROBED, color: false }),
    ).toBe(
      [
        "[work]",
        "  Weekly (all models)  ████████████████████ 120%",
        "  Status               Limited (weekly)",
      ].join("\n"),
    );
  });

  test("falls back to the windows' own statuses", () => {
    const session = limits({
      "anthropic-ratelimit-unified-5h-utilization": "1",
      "anthropic-ratelimit-unified-5h-status": "rejected",
      "anthropic-ratelimit-unified-7d-status": "allowed",
    });
    expect(
      formatSetupTokenProfile("work", session, { now: PROBED, color: false }),
    ).toEndWith("  Status        Limited (session)");
  });

  test("shows a status it doesn't know as received, and none for warnings", () => {
    const status = (value: string) =>
      formatSetupTokenProfile(
        "w",
        limits({ "anthropic-ratelimit-unified-status": value }),
        { now: PROBED, color: false },
      );
    expect(status("throttled")).toEndWith("  Status  throttled");
    expect(status("allowed_warning")).not.toContain("Status");
    expect(status("warning")).not.toContain("Status");
  });
});
