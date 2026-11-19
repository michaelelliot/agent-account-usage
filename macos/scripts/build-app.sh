#!/bin/sh
# Builds a release SubSmasher.app into macos/build/.
set -eu

cd "$(dirname "$0")/.."

swift build -c release --product SubSmasher
bin_dir="$(swift build -c release --show-bin-path)"

app=build/SubSmasher.app
if [ -d "$app" ]; then rm -r "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/SubSmasher" "$app/Contents/MacOS/SubSmasher"
cp Resources/Info.plist "$app/Contents/Info.plist"

# The icon at every size an .icns holds, from the 1024 px original.
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -r "$(dirname "$iconset")"

# Ad-hoc signature so the bundle runs locally on Apple silicon.
codesign --force --sign - "$app"

echo "Built $(pwd)/$app"
