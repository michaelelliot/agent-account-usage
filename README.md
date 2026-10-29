# agent-account-usage

Shows Claude.ai plan quota usage (5-hour session, weekly, per-model weekly, extra usage) for one or more accounts, either as a command-line tool or as a macOS menu bar app. Both read the same config file.

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
```

Each section needs one of:

- `claude_config_dir`: a Claude Code config directory (what you'd pass as `CLAUDE_CONFIG_DIR`). The OAuth token Claude Code stored for it is read from the macOS keychain, or from `<dir>/.credentials.json` on other platforms. Log in once with `CLAUDE_CONFIG_DIR=<dir> claude /login`.
- `oauth_token`: a literal Claude OAuth access token. Takes precedence if both are set.

An optional `name` is shown instead of the profile id (the CLI's `--json` stays keyed by profile id). Values may be wrapped in `"` or `'` quotes.

Tokens are only read, never refreshed, so neither tool can log Claude Code out. Claude Code access tokens expire after a few hours; if one has expired, run `claude` with that config dir and it will refresh it.

Usage comes from `GET https://api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code's `/usage` uses. It is undocumented and may change.

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
```

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
agent-usage --json               # raw API responses keyed by profile
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

A menu bar item showing a gauge and the highest utilization of the profile at the top of the list. The icon escalates as that gets close to the limit: the gauge's needle climbs at 50%, it turns orange at 75%, red with a warning at 90%, and becomes a red flame at 95%. Click it to see every profile's limits, reset times, extra usage and errors. Drag a profile up or down to reorder them (moving one to the top changes what the menu bar shows); the app remembers the order, while the CLI keeps config file order. It refreshes every 5 minutes, and when opened if the data is more than a minute old. The gear button opens the config in your default text editor, creating a starter file if there isn't one.

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

Open `macos/Package.swift` in Xcode to work on it there. `AgentUsageCore` holds the config, keychain and API code, and `AgentUsage` holds the SwiftUI app.
