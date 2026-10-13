#!/bin/sh
# Compatibility entry point for an existing source-checkout login launcher.
# New installations use the native Open Tana2D when I log in setting.
set -eu
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app=${TANA2D_APP:-/Applications/Tana2D.app}
if [ ! -x "$app/Contents/MacOS/tana2d" ]; then app="$root_dir/build/Tana2D.app"; fi
if [ ! -x "$app/Contents/MacOS/tana2d" ]; then
    printf '%s\n' 'Tana2D is missing. Run scripts/install.sh or install Tana2D.app.' >&2
    exit 75
fi
exec /usr/bin/open -g "$app"
