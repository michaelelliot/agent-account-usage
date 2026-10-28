# agent-account-usage

A small Bun CLI (`agent-usage`) that prints Claude.ai plan quota usage (5-hour session, weekly, per-model weekly, extra usage) for one or more accounts.

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

## Install

```sh
bun install
bun link   # puts `agent-usage` on your PATH
```

## Config

The config is an INI file in the style of `~/.aws/credentials`, at `~/.config/agent-usage/config` by default (override with `-c` or `AGENT_USAGE_CONFIG`). See [`config.example`](config.example).

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

An optional `name` is shown instead of the profile id when results are printed (`--json` stays keyed by profile id). Values may be wrapped in `"` or `'` quotes.

Tokens are only read, never refreshed, so the CLI can't log Claude Code out. Claude Code access tokens expire after a few hours; if one has expired, run `claude` with that config dir and it will refresh it.

## Usage

```
agent-usage                      # the [default] profile, or $AGENT_USAGE_PROFILE
agent-usage -p work -p personal  # specific profiles
agent-usage -a                   # every profile
agent-usage --json               # raw API responses keyed by profile
agent-usage list                 # profile names and credential source
```

The exit code is 1 if any profile failed (missing section, no login, expired token, HTTP error).

Usage comes from `GET https://api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code's `/usage` uses. It is undocumented and may change.

## Development

```sh
bun test
bun run typecheck
```
