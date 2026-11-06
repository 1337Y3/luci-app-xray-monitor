#!/bin/sh
# JS regression guards for the LuCI client-side code (CI runs this; node is
# the only requirement). See tests/js/check.js for what is covered and why.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
command -v node >/dev/null 2>&1 || { echo "node is required for tests/js-test.sh" >&2; exit 1; }
exec node "$HERE/js/check.js" "$HERE/.."
