#!/bin/sh
# Renders the README's screenshots into docs/: the menu, and the output of `agent-usage -a`, for sample accounts.
set -eu

cd "$(dirname "$0")/.."
docs="$(cd .. && pwd)/docs"
cli_output="$(mktemp)"
trap 'rm -f "$cli_output"' EXIT

(cd ../cli && bun scripts/sample-output.ts) >"$cli_output"
mkdir -p "$docs"
AGENT_USAGE_SCREENSHOTS="$docs" AGENT_USAGE_CLI_OUTPUT="$cli_output" swift test --filter Screenshots
