#!/bin/sh
# Builds a release AgentUsage.app into macos/build/.
set -eu

cd "$(dirname "$0")/.."

swift build -c release --product AgentUsage
bin_dir="$(swift build -c release --show-bin-path)"

app=build/AgentUsage.app
if [ -d "$app" ]; then rm -r "$app"; fi
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/AgentUsage" "$app/Contents/MacOS/AgentUsage"
cp Resources/Info.plist "$app/Contents/Info.plist"

# Ad-hoc signature so the bundle runs locally on Apple silicon.
codesign --force --sign - "$app"

echo "Built $(pwd)/$app"
