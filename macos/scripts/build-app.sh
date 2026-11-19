#!/bin/sh
# Builds a release SubSmasher.app into macos/build/.
set -eu

cd "$(dirname "$0")/.."

swift build -c release --product SubSmasher
bin_dir="$(swift build -c release --show-bin-path)"

app=build/SubSmasher.app
if [ -d "$app" ]; then rm -r "$app"; fi
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/SubSmasher" "$app/Contents/MacOS/SubSmasher"
cp Resources/Info.plist "$app/Contents/Info.plist"

# Ad-hoc signature so the bundle runs locally on Apple silicon.
codesign --force --sign - "$app"

echo "Built $(pwd)/$app"
