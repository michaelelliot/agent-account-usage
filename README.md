# agent-account-usage

Shows plan quota usage for one or more Claude.ai, ChatGPT (Codex) and Grok accounts, either as a command-line tool or as a macOS menu bar app. Both read the same config file. For Claude that's the 5-hour session, weekly and per-model weekly limits plus extra usage; for ChatGPT it's the Codex limits, your credit balance and any limit resets you have available; for Grok it's Grok Bot's weekly usage and any banked resets.

| Path             | What                                                |
| ---------------- | --------------------------------------------------- |
| `cli/`           | `agent-usage`, a Bun + commander CLI                |
| `macos/`         | Agent Usage, a SwiftUI menu bar app (Swift package) |
| `config.example` | Sample config for both                              |

## Config

The config is an INI file in the style of `~/.aws/credentials`, at `~/.config/agent-usage/config` by default (override with `AGENT_USAGE_CONFIG`, or `-c` for the CLI). See [`config.example`](config.example).

```ini
[default]
name = "me@example.com"
claude_config_dir = ~/.claude

[personal]
claude_config_dir = ~/.claude-personal

[work]
oauth_token = sk-ant-oat01-...

[chatgpt]
name = "ChatGPT"
codex_home = ~/.codex

[grok]
name = "Grok"
cursor_dir = ~/Library/Application Support/Cursor
```

Each section needs one of:

- `claude_config_dir`: a Claude Code config directory (what you'd pass as `CLAUDE_CONFIG_DIR`). The OAuth token Claude Code stored for it is read from the macOS keychain, or from `<dir>/.credentials.json` on other platforms. Log in once with `CLAUDE_CONFIG_DIR=<dir> claude /login`.
- `oauth_token`: a literal Claude OAuth access token. Takes precedence over `claude_config_dir` if both are set.
- `codex_home`: a Codex home directory (what you'd pass as `CODEX_HOME`, `~/.codex` by default). The ChatGPT desktop app and the `codex` CLI both keep your ChatGPT login in `<dir>/auth.json`, and that's read. Sign in with either one first. A Codex signed in with an API key has no plan limits to show.
- `cursor_dir`: Cursor's data directory (`~/Library/Application Support/Cursor` on macOS). Grok Bot is a Cursor app that signs in with a Cursor account, so this shows Grok Bot's usage for the account signed in to Cursor. Grok Bot keeps its own login somewhere it can't be read, so Cursor needs to be signed in to the same account. Cursor encrypts its saved login with a key in the macOS keychain, so the first read makes macOS ask to let `security` access "Cursor Safe Storage". Choose Always Allow or it will ask on every refresh. That also lets any other program that runs `security` read the key.

An optional `name` is shown instead of the profile id (the CLI's `--json` stays keyed by profile id). An optional `claude_path` says where `claude` is, for refreshing that profile's token (see below). Values may be wrapped in `"` or `'` quotes.

Tokens are only read: neither tool calls the OAuth refresh endpoint or writes a login, so neither can log Claude Code or Codex out. Claude Code access tokens expire after a few hours. When one has, both tools get Claude Code to refresh it by running `claude -p /cost` with that config dir (and with `CLAUDE_CONFIG_DIR` unset for a `~/.claude` login, which Claude Code keeps under a different keychain name). They run it from a temp directory, without loading project settings or MCP servers and without saving the session, then read the token again. `/cost` runs locally, so this doesn't call the model or use any quota. It takes a few seconds. `claude` is looked for on your PATH, then in `~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin` and `/usr/local/bin` (an app opened from Finder gets a minimal PATH). If refreshing fails, the app tries again after half an hour (straight away if you change `claude_path`); if the sign-in itself has ended, run `claude` yourself the same way. ChatGPT tokens last about 10 days and Codex refreshes them as you use it. Cursor's are long-lived and Cursor refreshes them.

Claude usage comes from `GET https://api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code's `/usage` uses. ChatGPT usage comes from `GET https://chatgpt.com/backend-api/wham/usage` (and `/wham/rate-limit-reset-credits` for when your resets expire), which is what Codex uses. Grok usage comes from Cursor's `https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus` (and `ListSandBankedResets`), which is what Grok Bot uses. All of them are undocumented and may change.

## CLI

```
$ agent-usage -a
[default]  max
  Session (5h)  ░░░░░░░░░░░░░░░░░░░░   0%
  Weekly        ████████████████████  98%  resets in 1d 8h
  Weekly Fable  ██░░░░░░░░░░░░░░░░░░   8%  resets in 1d 8h

[personal]  max
  Session (5h)  ░░░░░░░░░░░░░░░░░░░░   0%  resets in 4h 54m
  Weekly        ██░░░░░░░░░░░░░░░░░░   8%  resets in 1d 14h
  Weekly Fable  ░░░░░░░░░░░░░░░░░░░░   0%  resets in 1d 14h
  Extra usage   $26.66 / $40.00 (67%)  disabled (out of credits)

[ChatGPT]  pro
  Weekly        ████████████████████ 100%  resets in 11h 24m
  Credits       60,511  in use until the limit resets
  Limit resets  3 available  next expires in 3d 4h

[Grok]  Ultra
  Weekly  ██████░░░░░░░░░░░░░░  32%  resets in 2d 18h
```

Credits are what Codex spends once you hit a plan limit. Limit resets are one-off full resets you can use from the ChatGPT usage page; the soonest expiry is shown because they expire.

### Install

```sh
cd cli
bun install
bun link   # puts `agent-usage` on your PATH
```

### Usage

```
agent-usage                      # the [default] profile, or $AGENT_USAGE_PROFILE
agent-usage -p work -p personal  # specific profiles
agent-usage -a                   # every profile
agent-usage --json               # raw API responses keyed by profile ({usage, reset_credits} for ChatGPT, {usage, banked_resets} for Grok)
agent-usage list                 # profile names and credential source
```

Output is coloured when stdout is a terminal. Set `NO_COLOR=1` to turn colours off, or `FORCE_COLOR=1` to keep them when piping.

The exit code is 1 if any profile failed (missing section, no login, expired token, HTTP error).

### Development

```sh
cd cli
bun test
bun check   # type check
bun fmt     # format
```

## macOS app

A menu bar item showing a gauge and the highest utilization of the profile at the top of the list. The icon escalates as that gets close to the limit: the gauge's needle climbs at 50%, it turns orange at 75%, red with a warning at 90%, and becomes a red flame at 95%. Click it to see every profile's limits, reset times, extra usage, ChatGPT credits and limit resets, and errors. Drag a profile up or down to reorder them (moving one to the top changes what the menu bar shows); the app remembers the order, while the CLI keeps config file order. It refreshes every 5 minutes, and when opened if the data is more than a minute old. The gear button opens the config in your default text editor, creating a starter file if there isn't one.

Needs macOS 14 or later and the Swift 6 toolchain that comes with Xcode.

### Build and install

```sh
cd macos
./scripts/build-app.sh        # builds build/AgentUsage.app (ad-hoc signed)
open build/AgentUsage.app
```

To keep it, copy `build/AgentUsage.app` to `/Applications` and add it under System Settings > General > Login Items.

### Development

```sh
cd macos
swift run AgentUsage                               # run without bundling
swift test
AGENT_USAGE_LIVE_TEST=1 swift test --filter live   # also hits the real API with your config
```

Open `macos/Package.swift` in Xcode to work on it there. `AgentUsageCore` holds the config, credential and API code (Codex in `Codex.swift`, Grok in `Grok.swift`), and `AgentUsage` holds the SwiftUI app.
