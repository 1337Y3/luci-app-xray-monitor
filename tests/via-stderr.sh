#!/bin/sh
# Exercise the production via helpers after a real tmpxray stop held fd 4.
# A normal first start runs in $(...) and cannot set the parent's theld.
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/xraymon-via-stderr.XXXXXX")
trap 'rm -rf "$W"' EXIT
command -v flock >/dev/null 2>&1 || { echo 'flock required' >&2; exit 1; }
export W
SUB="$REPO/files/usr/share/xray-monitor/xray-sub"
sed -n '/^tmpxray_take_lock()/,/^tmpxray_pick_ports()/p' "$SUB" | sed '$d' > "$W/helpers"
sed -n '/^do_tmpxray_stop()/,/^# --- e2e:/p' "$SUB" | sed '$d' >> "$W/helpers"
sed -n '/^via_start()/,/^# --- mieru client tab/p' "$SUB" | sed '$d' >> "$W/helpers"
cat > "$W/run" <<'SH'
set -eu
. "$W/helpers"
TLOCK="$W/lock"
theld=0; via_started=0; via_err=''
# Only process/config boundaries are stubbed; stop and via lock handling are real.
tmpxray_kill() { echo stopped; }
do_tmpxray_start() {
	if [ "$1" = missing ]; then echo '{"pid":1,"ports":{}}'
	else echo '{"pid":1,"ports":{"proxy-de":11080}}'; fi
}
do_tmpxray_stop >/dev/null
[ "$theld" = 1 ]
if via_start "$1"; then
	[ "$VIA_PORT" = 11080 ]
	[ "$theld" = 0 ]
	# Closing fd 4 must also release the lock to another open description.
	( exec 5>>"$TLOCK"; flock -n 5 )
	if ( : >&4 ) 2>/dev/null; then exit 1; fi
	via_stop
	echo 'caller: transfer failed' >&2
else
	echo "caller: proxy path unavailable: $via_err" >&2
fi
SH
sh "$W/run" proxy-de > "$W/out" 2> "$W/err"
[ ! -s "$W/out" ]
grep -qx 'caller: transfer failed' "$W/err"
echo 'PASS via_start preserves caller stderr and releases fd 4'
sh "$W/run" missing > "$W/out" 2> "$W/err"
[ ! -s "$W/out" ]
grep -qx 'caller: proxy path unavailable: tmpxray started but reported no port for missing' "$W/err"
echo 'PASS via_start malformed reply retains actionable caller diagnostic'
