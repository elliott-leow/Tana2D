#!/bin/sh
# Build and install Tana2D without sudo.
set -eu
usage() { printf '%s\n' 'usage: scripts/install.sh [--destination PATH] [--no-build] [--no-open]'; }
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); root_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
destination=/Applications/Tana2D.app; no_build=0; no_open=0
while [ "$#" -gt 0 ]; do case "$1" in --destination) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; destination=$2; shift 2 ;; --no-build) no_build=1; shift ;; --no-open) no_open=1; shift ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 64 ;; esac; done
case "$destination" in *.app) ;; *) printf '%s\n' 'install.sh: destination must end in .app' >&2; exit 64 ;; esac
package_script=${TANA2D_PACKAGE_SCRIPT:-"$script_dir/package.sh"}; app_source=${TANA2D_APP_SOURCE:-"$root_dir/build/Tana2D.app"}; open_command=${TANA2D_OPEN_COMMAND:-open}
if [ "$no_build" -eq 1 ]; then "$package_script" --no-build; else "$package_script"; fi
if [ -L "$app_source" ] || [ ! -d "$app_source" ] || [ ! -x "$app_source/Contents/MacOS/tana2d" ]; then printf '%s\n' "install.sh: packaged app is incomplete or symlinked: $app_source" >&2; exit 1; fi
parent_dir=$(CDPATH= cd -- "$(dirname -- "$destination")" 2>/dev/null && pwd) || { printf '%s\n' "install.sh: destination folder does not exist or is inaccessible: $(dirname -- "$destination")" >&2; exit 1; }
if [ "$parent_dir" = / ]; then printf '%s\n' 'install.sh: refusing a root-level app destination.' >&2; exit 64; fi
if [ ! -w "$parent_dir" ]; then printf '%s\n' "install.sh: cannot write to $parent_dir. Copy build/Tana2D.app there in Finder or choose --destination in a writable folder." >&2; exit 1; fi
destination="$parent_dir/$(basename -- "$destination")"
if [ -L "$destination" ]; then printf '%s\n' "install.sh: refusing symlink destination: $destination" >&2; exit 1; fi
if [ -e "$destination" ]; then
    info_plist="$destination/Contents/Info.plist"
    existing_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)
    case "$existing_identifier" in dev.tana2d.manager) ;; *) printf '%s\n' "install.sh: refusing to replace an unrelated app at $destination" >&2; exit 1 ;; esac
fi
stage_dir=$(mktemp -d "$parent_dir/.Tana2D.install.XXXXXX"); backup="${parent_dir}/.Tana2D.previous.$$.app"; installed=0
cleanup() { rm -rf "$stage_dir"; if [ "$installed" -eq 0 ] && [ -e "$backup" ] && [ ! -e "$destination" ]; then mv "$backup" "$destination"; fi; }; trap cleanup EXIT HUP INT TERM
cp -R "$app_source" "$stage_dir/Tana2D.app"
if [ -e "$destination" ]; then mv "$destination" "$backup"; fi
if ! mv "$stage_dir/Tana2D.app" "$destination"; then printf '%s\n' "install.sh: could not replace $destination; the previous app will be restored." >&2; exit 1; fi
installed=1; rm -rf "$backup"; printf '%s\n' "installed $destination"
if [ "$no_open" -eq 0 ] && ! "$open_command" "$destination"; then printf '%s\n' "install.sh: installed Tana2D, but could not open it. Open $destination manually." >&2; exit 1; fi
