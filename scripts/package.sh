#!/bin/sh
# Build a local app bundle. This script never installs or launches Tana2D.
set -eu
usage() { printf '%s\n' 'usage: scripts/package.sh [--no-build]'; }
no_build=0
case "${1-}" in '') ;; --no-build) no_build=1 ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 64 ;; esac
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
build_dir="$root_dir/build"; binary="$build_dir/tana2d"; app="$build_dir/Tana2D.app"
codesign_command=${TANA2D_CODESIGN:-/usr/bin/codesign}
identity=${TANA2D_SIGN_ID:-}
if [ -z "$identity" ] && [ -f "$build_dir/signing-identity" ]; then identity=$(cat "$build_dir/signing-identity"); fi
identity=${identity:--}
if [ "$no_build" -eq 0 ]; then make -C "$root_dir" all; fi
if [ ! -f "$binary" ] || [ ! -x "$binary" ]; then printf '%s\n' "package.sh: missing executable $binary (run make all first)" >&2; exit 1; fi
if [ ! -x "$codesign_command" ]; then printf '%s\n' "package.sh: codesign is unavailable at $codesign_command" >&2; exit 1; fi
mkdir -p "$build_dir"; stage_dir=$(mktemp -d "$build_dir/.Tana2D.package.XXXXXX"); stage_app="$stage_dir/Tana2D.app"
cleanup() { rm -rf "$stage_dir"; }; trap cleanup EXIT HUP INT TERM
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources" "$stage_app/Contents/Helpers"
cp "$binary" "$stage_app/Contents/MacOS/tana2d"; chmod 0755 "$stage_app/Contents/MacOS/tana2d"
# A separately signed nested executable remains valid outside the app bundle.
# The main app executable gains an Info.plist seal and cannot serve that role.
cp "$binary" "$stage_app/Contents/Helpers/tana2d-window-helper"
chmod 0755 "$stage_app/Contents/Helpers/tana2d-window-helper"
cp "$root_dir/vendor/yabai/LICENSE.txt" "$stage_app/Contents/Resources/THIRD-PARTY-NOTICES.txt"
if [ -f "$root_dir/docs/SETUP.html" ]; then cp "$root_dir/docs/SETUP.html" "$stage_app/Contents/Resources/SETUP.html"; fi
cat > "$stage_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Tana2D</string>
  <key>CFBundleExecutable</key><string>tana2d</string>
  <key>CFBundleIdentifier</key><string>dev.tana2d.manager</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Tana2D</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4.0</string>
  <key>CFBundleVersion</key><string>0.4.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
if [ "${TANA2D_NOTARIZE:-0}" = 1 ]; then
    if [ "$identity" = '-' ]; then printf '%s\n' 'package.sh: TANA2D_NOTARIZE=1 requires TANA2D_SIGN_ID for a Developer ID signature.' >&2; exit 64; fi
    sign_flags='--force --options runtime --timestamp'
else
    sign_flags='--force --timestamp=none'
fi
# shellcheck disable=SC2086 -- fixed literal flags, separately quoted identity/path.
"$codesign_command" $sign_flags --sign "$identity" --identifier dev.tana2d.window-helper "$stage_app/Contents/Helpers/tana2d-window-helper"
# shellcheck disable=SC2086 -- the flag lists above are fixed literals.
if ! "$codesign_command" $sign_flags --sign "$identity" "$stage_app/Contents/MacOS/tana2d"; then printf '%s\n' 'package.sh: codesign failed for executable' >&2; exit 1; fi
# shellcheck disable=SC2086 -- the flag lists above are fixed literals.
if ! "$codesign_command" $sign_flags --sign "$identity" "$stage_app"; then printf '%s\n' 'package.sh: codesign failed for app bundle' >&2; exit 1; fi
"$codesign_command" --verify --deep --strict "$stage_app"
# Verify the privileged helper in the same standalone form used by installation.
cp "$stage_app/Contents/Helpers/tana2d-window-helper" "$stage_dir/window-helper"
"$codesign_command" --verify --strict "$stage_dir/window-helper"
rm "$stage_dir/window-helper"
# The previous bundle remains intact until a signed, verified replacement exists.
# Renaming directories cannot replace an existing directory atomically on macOS,
# so retain it as a rollback until the staged app is in place.
backup="$build_dir/.Tana2D.previous.$$.app"; replaced=0
restore() { if [ "$replaced" -eq 0 ] && [ -e "$backup" ] && [ ! -e "$app" ]; then mv "$backup" "$app"; fi; }
trap 'restore; cleanup' EXIT HUP INT TERM
if [ -e "$app" ]; then mv "$app" "$backup"; fi
mv "$stage_app" "$app"; replaced=1
rm -rf "$backup"
if [ "$identity" != '-' ]; then (umask 077; printf '%s\n' "$identity" > "$build_dir/signing-identity"); fi
printf '%s\n' "created $app"; printf '%s\n' "signing identity: $identity"
