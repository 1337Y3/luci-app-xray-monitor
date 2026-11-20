#!/bin/sh
# The production claim and RPC arm, with only the worker/tool boundaries stubbed.
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/mieru-marker.XXXXXX")
trap 'rm -rf "$W"' EXIT
REAL_FLOCK=$(command -v flock) || { echo 'flock required' >&2; exit 1; }
export REAL_FLOCK W
sed -n '/^mieru_marker_live()/,/^mieru_ids()/p' "$REPO/files/usr/share/xray-monitor/xray-sub" | sed '$d' > "$W/helpers"
awk '/^[[:space:]]*mieru_install\)/ { active=1 } active { print } active && /^[[:space:]]*;;/ { exit }' "$REPO/files/usr/libexec/rpcd/xray-monitor" > "$W/arm"
# A successful lock followed by an unwritable publication target simulates
# ENOSPC/write failure after opening the marker; ordinary chmod misses this.
cat > "$W/common" <<'SH'
E2E_STATE="$W/state"
mkdir -p "$E2E_STATE"
MIERU_RUN_MARKER="$E2E_STATE/mieru-install.run"
: > "$MIERU_RUN_MARKER"
flock() {
	"$REAL_FLOCK" "$@" || return $?
	if [ "$1" = -n ] && [ "${FAIL_WRITE:-0}" = 1 ]; then
		mv "$MIERU_RUN_MARKER" "$MIERU_RUN_MARKER.saved"
		mkdir "$MIERU_RUN_MARKER"
		FAIL_WRITE=0
	fi
}
SH
cat > "$W/claim" <<'SH'
. "$W/common"
. "$W/helpers"
if mieru_marker_claim; then echo 'claim unexpectedly succeeded' >&2; exit 1; fi
SH
FAIL_WRITE=1 sh "$W/claim" > "$W/out" 2>&1
grep -q 'cannot publish the install worker pid' "$W/out"
echo 'PASS worker PID publication fails closed'
rm -rf "$W/state"
cat > "$W/reserved" <<'SH'
. "$W/common"
. "$W/helpers"
MIERU_RESERVED=1
if mieru_marker_claim; then echo 'unpublished RPC worker unexpectedly claimed' >&2; exit 1; fi
SH
sh "$W/reserved" > "$W/out" 2>&1
grep -q 'reservation was not published' "$W/out"
echo 'PASS RPC worker requires parent reservation'
rm -rf "$W/state"
cat > "$W/mieru.uc" <<'SH'
#!/bin/sh
printf '%s\n' '{"ok":false,"msg":"fallback","ts":1}'
SH
cat > "$W/worker" <<'SH'
#!/bin/sh
. "$W/helpers"
MIERU_RUN_MARKER="$W/state/mieru-install.run"
mieru_marker_claim || exit 1
touch "$W/WORK_STARTED"
mieru_marker_clear
SH
chmod +x "$W/mieru.uc" "$W/worker"
# The production RPC arm launches this sandbox worker, never a live path.
sed "s|/usr/share/xray-monitor/xray-sub|$W/worker|g" "$W/arm" > "$W/sandbox-arm"
{
	cat <<'SH'
. "$W/common"
SHARE="$W"
SUB="$W/worker"
jsonfilter() { cat >/dev/null; }
json_init() { :; }
json_add_boolean() { echo "$1=$2"; }
json_add_string() { echo "$1=$2"; }
json_dump() { :; }
case mieru_install in
SH
	cat "$W/sandbox-arm"
	echo esac
} > "$W/rpc"
FAIL_WRITE=1 sh "$W/rpc" </dev/null > "$W/out" 2>&1
grep -q 'ok=0' "$W/out"
grep -q 'cannot publish the install worker pid' "$W/out"
[ ! -e "$W/WORK_STARTED" ]
echo 'PASS RPC PID publication failure returns a clear failure before work'
rm -rf "$W/state"
mkdir -p "$W/state/mieru-install.result.new"
sh "$W/rpc" </dev/null > "$W/out" 2>&1
grep -q 'ok=0' "$W/out"
grep -q 'cannot publish the install outcome' "$W/out"
[ ! -e "$W/WORK_STARTED" ]
echo 'PASS RPC outcome publication failure prevents launch'
rm -rf "$W/state"
chmod -x "$W/worker"
sh "$W/rpc" </dev/null > "$W/out" 2>&1
grep -q 'ok=0' "$W/out"
grep -q 'cannot launch the install worker' "$W/out"
echo 'PASS missing executable worker returns a clear launch failure'
chmod +x "$W/worker"
rm -rf "$W/state"
printf '#!/bin/sh\nexit 127\n' > "$W/worker"
sh "$W/rpc" </dev/null > "$W/out" 2>&1
grep -q '"msg":"fallback"' "$W/state/mieru-install.result"
[ ! -e "$W/WORK_STARTED" ]
echo 'PASS abruptly exiting worker retains a terminal failure outcome'
