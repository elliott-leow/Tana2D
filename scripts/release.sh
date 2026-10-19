#!/bin/sh
# Create a drag-and-drop release artifact. ZIP is the default.
set -eu
usage() { printf '%s\n' 'usage: scripts/release.sh [--format zip|dmg] [--no-build] [--output DIR]'; }
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); root_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
package_script=${TANA2D_PACKAGE_SCRIPT:-"$script_dir/package.sh"}; app_source=${TANA2D_APP_SOURCE:-"$root_dir/build/Tana2D.app"}
ditto_command=${TANA2D_DITTO:-/usr/bin/ditto}; xcrun_command=${TANA2D_XCRUN:-xcrun}
format=zip; no_build=0; output_dir="$root_dir/dist"
while [ "$#" -gt 0 ]; do case "$1" in --format) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; format=$2; shift 2 ;; --no-build) no_build=1; shift ;; --output) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; output_dir=$2; shift 2 ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 64 ;; esac; done
case "$format" in zip|dmg) ;; *) usage >&2; exit 64 ;; esac
if [ "$no_build" -eq 1 ]; then "$package_script" --no-build; else "$package_script"; fi
app="$app_source"; [ -d "$app" ] || { printf '%s\n' "release.sh: missing $app" >&2; exit 1; }
mkdir -p "$output_dir"; stage_dir=$(mktemp -d "$output_dir/.Tana2D.release.XXXXXX"); trap 'rm -rf "$stage_dir"' EXIT HUP INT TERM
if [ "${TANA2D_NOTARIZE:-0}" = 1 ]; then
    [ -n "${TANA2D_NOTARY_PROFILE:-}" ] || { printf '%s\n' 'release.sh: TANA2D_NOTARIZE=1 requires TANA2D_NOTARY_PROFILE.' >&2; exit 64; }
    # notarytool accepts an archive, not an .app directory. Staple the app
    # before producing the user-facing ZIP or DMG so either contains the ticket.
    submission_zip="$stage_dir/Tana2D-notarization.zip"
    "$ditto_command" -c -k --sequesterRsrc --keepParent "$app" "$submission_zip"
    "$xcrun_command" notarytool submit "$submission_zip" --keychain-profile "$TANA2D_NOTARY_PROFILE" --wait
    "$xcrun_command" stapler staple "$app"
fi
if [ "$format" = zip ]; then artifact="$output_dir/Tana2D-0.4.0.zip"; "$ditto_command" -c -k --sequesterRsrc --keepParent "$app" "$stage_dir/Tana2D-0.4.0.zip"
else artifact="$output_dir/Tana2D-0.4.0.dmg"; "${TANA2D_DMG_SCRIPT:-$script_dir/dmg.sh}" "$app" "$stage_dir/Tana2D-0.4.0.dmg" >/dev/null; fi
mv "$stage_dir/$(basename -- "$artifact")" "$artifact"; printf '%s\n' "created $artifact"; printf '%s\n' 'release architecture: host-native (universal payload builds are not yet validated)'
