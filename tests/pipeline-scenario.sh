#!/bin/sh
# Sandbox scenario for the config write pipeline in xray-sub (F-prep:
# commit_config + post_restart_hooks + no-restart mode). Everything runs inside
# a throwaway sandbox: a copy of xray-sub with EVERY writable path it mentions
# rewritten into the sandbox (config, state, backups, staging, both locks,
# tmpxray state, crontab, init scripts, /tmp downloads), the real .uc
# transforms, and stubs for xray / pgrep / uci / opkg / the init scripts that
# only log. The live router is never touched - no service restart, nothing
# outside the sandbox is written; a setup safety net aborts if any live
# writable path is still reachable in the copy.
#   sh tests/pipeline-scenario.sh [sandbox-dir]     (needs ucode + ucode-mod-fs)
#   KEEP_SB=1 sh tests/pipeline-scenario.sh ...     keep the sandbox for review
# Covered, per write path (apply / routing-set / balancers-set / config-save /
# enable-api): backup name+kind, candidate validated then installed, restart
# invoked, post_restart_hooks fired, prune_backups run; plus the test-failed
# path, the verify-failed (rollback) path, a config.json that is a SYMLINK
# (snapshot must dereference, rollback must restore through the link),
# no-restart (install only), a prune failure that must not fail the write,
# the F15 sticky-override re-apply in post_restart_hooks (stubbed bo + sandbox
# UCI), and the mutation lock itself: a held flock fails a NOWAIT writer at once and a
# waiting writer succeeds after the holder lets go (only where flock(1) is
# real - a stubbed flock serializes nothing).
# F13 adds the e2e exit check: the real runner (tmpxray start via stubbed
# xray/netstat + stubbed curl) producing ok / stalled / fail verdicts and a
# skipped verdict for a probe_disabled exit that is never dialled, the run
# marker + progress file while running, tmpxray stopped afterwards, and the
# cron-sync line for the e2e schedule (needs ucode + ucode-mod-fs + jsonfilter
# + busybox tools).
# F17 adds the rpcd backend's own contract, through a sandboxed copy of the
# rpcd script driving the sandboxed xray-sub above: config_get's "hash" (md5 of
# the file bytes, through a symlink, empty when the file is gone), config_save's
# optimistic lock (the right hash saves, a stale one is refused with conflict=1
# and touches nothing, no/empty hash keeps the old behavior), config_diff_text
# (semantic diff of the editor text vs the live config, invalid JSON named as
# such), and list/ACL consistency for every declared method.
# The F18 sections cover fetches / self-updates routed through a tmpxray socks
# instance: the auto exit-selection order (fresh e2e.json first, then the rpcd
# outbounds fallback), the same UA / timeout / header capture on the proxied
# curl, honest failures when nothing is selectable or tmpxray cannot start
# (never a silent direct fallback), the self-update downloads proxied while
# opkg stays local and the SHA256 gate stays strict, and the instance being
# stopped before opkg install. curl / ubus / tmpxray are stubbed there; uci
# answers come from a file the cases rewrite.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
FIX="$REPO/tests/fixtures"
SHARESRC="$REPO/files/usr/share/xray-monitor"

command -v ucode >/dev/null 2>&1 || { echo "ucode not found in PATH"; exit 1; }
ucode -e 'import { readfile } from "fs";' >/dev/null 2>&1 \
	|| { echo "ucode-mod-fs not installed"; exit 1; }

SB=${1:-}
[ -n "$SB" ] || SB=$(mktemp -d "${TMPDIR:-/tmp}/xraymon-pipeline.XXXXXX") || exit 1
mkdir -p "$SB" 2>/dev/null && SB=$(cd "$SB" && pwd) || { echo "cannot use sandbox dir: $SB"; exit 1; }
case "$SB" in *'|'*|*'&'*) echo "sandbox path must not contain | or &"; exit 1 ;; esac
KEEP=${KEEP_SB:-0}
cleanup() {
	[ "$KEEP" = 1 ] || rm -rf "$SB"
	# The pgrep stub hides tmpxray TTL watchdogs from xray-sub's stop sweep, so
	# a leftover `sleep <ttl>` could outlive the sandbox. Reap them by cmdline
	# via the busybox multicall (not shadowed by $SB/bin) where available.
	if command -v busybox >/dev/null 2>&1; then
		busybox pgrep -f "$SB/tmp/tmpxray\\." 2>/dev/null \
			| while IFS= read -r p; do kill "$p" 2>/dev/null; done
	fi
	return 0
}
trap cleanup EXIT

mkdir -p "$SB/bin" "$SB/etc/init.d" "$SB/etc/xray" "$SB/state" "$SB/lock" "$SB/log" \
	"$SB/work" "$SB/tmp" "$SB/share" "$SB/flags" "$SB/tmp/xray-monitor" "$SB/curltab"
cp -a "$SHARESRC" "$SB/share/xray-monitor"

# The sandboxed copy: same code, every writable path pointed into the sandbox
# (write pipeline, both locks, tmpxray state, cron-sync, self-update's
# download). post_restart_hooks gets a logging body so the scenario can
# observe it; everything else is byte-identical to the installed script.
# The second xray-sub rule rewrites the ESCAPED form inside cron-sync's two
# sed-delete patterns ("." swallows the backslash): the appended cron lines
# carry the sandbox path, so the deletions must match that form too.
sed \
	-e "s|^SHARE=.*|SHARE=$SB/share/xray-monitor|" \
	-e "s|^STATE=.*|STATE=$SB/state|" \
	-e "s|^XRAY=.*|XRAY=$SB/bin/xray|" \
	-e "s|^LOCK=.*|LOCK=$SB/lock/xray-monitor|" \
	-e "s|^TLOCK=.*|TLOCK=$SB/lock/xray-monitor-tmpxray|" \
	-e "s|^TSTATE_DIR=.*|TSTATE_DIR=$SB/tmp/xray-monitor|" \
	-e "s|echo \"/etc/xray/config.json\"|echo \"$SB/etc/xray/config.json\"|" \
	-e "s|/etc/init\.d/xray|$SB/etc/init.d/xray|g" \
	-e "s|/etc/init\.d/cron|$SB/etc/init.d/cron|g" \
	-e "s|/etc/crontabs|$SB/etc/crontabs|g" \
	-e "s|/usr/share/xray-monitor/xray-sub|$SB/sub|g" \
	-e "s|xray-monitor./xray-sub|sub|g" \
	-e "s|/tmp/luci-app-xray-monitor\.ipk|$SB/tmp/luci-app-xray-monitor.ipk|g" \
	-e 's|^post_restart_hooks() {$|post_restart_hooks() { echo hook >> "${STUB_HOOK_LOG:-/dev/null}";|' \
	"$SHARESRC/xray-sub" > "$SB/sub"
for pat in "SHARE=$SB" "STATE=$SB" "XRAY=$SB" "LOCK=$SB" "TLOCK=$SB" "TSTATE_DIR=$SB" \
	"$SB/etc/xray/config.json" "$SB/etc/init.d/xray" "$SB/etc/crontabs/root" \
	"$SB/etc/init.d/cron" "STUB_HOOK_LOG"; do
	grep -q -- "$pat" "$SB/sub" || { echo "scenario setup failed, rewrite missed: $pat"; exit 1; }
done
# safety net: mask the sandbox references (and the /etc, /tmp they cover),
# then no live writable path may remain in the copy - including the real
# /var/lock and /tmp/xray-monitor that TLOCK / TSTATE_DIR would otherwise use
sed -e "s|$SB|<SB>|g" -e 's|<SB>/etc||g' -e 's|<SB>/tmp||g' "$SB/sub" > "$SB/work/sub-check.txt"
if grep -q 'echo "/etc/xray' "$SB/work/sub-check.txt" \
	|| grep -Eq '/etc/(init\.d|xray|crontabs)' "$SB/work/sub-check.txt" \
	|| grep -q '/var/lock' "$SB/work/sub-check.txt" \
	|| grep -q '/tmp/luci-app' "$SB/work/sub-check.txt" \
	|| grep -q '/tmp/xray-monitor' "$SB/work/sub-check.txt"; then
	echo "scenario setup failed: a live writable path is still reachable in the copy"; exit 1
fi

# tmpxray override for the F18 fetch-via sections: the contract-B2 boundary is
# stubbed (start prints the JSON with a fixed port, stop logs), so proxied
# fetch/update cases need no real xray, bound ports or netstat. Inserted before
# the first dispatcher `case` (after the real definitions, so the override wins
# in ash); the $STAGE_DIR lib extraction below then carries it too, harmlessly.
# GUARDED by $STUB_TMPXRAY_OVERRIDE: only the F18 sections export it - the F13
# e2e sections need the REAL tmpxray machinery (ports, state file, netstat).
cat > "$SB/work/tmpxray-override.sh" <<'EOF'

# --- scenario override: stub the tmpxray (B2) start/stop boundary -----------
if [ -n "${STUB_TMPXRAY_OVERRIDE:-}" ]; then
do_tmpxray_start() {
	echo "start $*" >> "${STUB_TMPXRAY_LOG:-/dev/null}"
	[ -f "${STUB_TMPXRAY_FAIL:-/nonexistent}" ] && { echo "stub: tmpxray start failed"; return 1; }
	printf '{"pid":%s,"ports":{"%s":%s}}\n' "$$" "$1" "${STUB_TMPXRAY_PORT:-11080}"
}
do_tmpxray_stop() {
	echo "stop" >> "${STUB_TMPXRAY_LOG:-/dev/null}"
	echo "stopped"
	return 0
}
fi
EOF
awk -v ins="$SB/work/tmpxray-override.sh" '
	!done && $0 == "case \"$1\" in" { while ((getline line < ins) > 0) print line; close(ins); done = 1 }
	{ print }
' "$SB/sub" > "$SB/sub.new" && mv "$SB/sub.new" "$SB/sub"
[ "$(grep -c '^do_tmpxray_start()' "$SB/sub")" = 2 ] \
	|| { echo "scenario setup failed: tmpxray override not inserted"; exit 1; }

# Writers serialize with flock(2) on an open descriptor (`flock FD`, busybox
# and util-linux alike). Where no flock exists (dev boxes) fall back to a
# no-op stub: the pipeline still runs, but nothing serializes - the lock
# assertions below are skipped there.
FLOCK_STUB=0
if ! command -v flock >/dev/null 2>&1; then
	printf '#!/bin/sh\n# no-op flock(1) stand-in (no real flock on this box): no serialization\nexit 0\n' > "$SB/bin/flock"
	chmod 0755 "$SB/bin/flock"
	FLOCK_STUB=1
	echo "NOTE   flock(1) not found - using a no-op stub, lock cases skipped"
fi

cat > "$SB/bin/xray" <<'EOF'
#!/bin/sh
# xray stub: `-test` validates by marker, `api ...` models the HandlerService
# (F14): the running outbound tags live in $STUB_API_OB (one per line);
# lso prints them, rmo/ado mutate them the way the real service does (rmo of
# an unknown tag succeeds silently, ado fails on an existing tag). Every
# `-test` (and its verdict) is logged to $STUB_LOG.
LOG=${STUB_LOG:-/dev/null}
OB=${STUB_API_OB:-/dev/null}
case "$1" in
	-test)
		cfg=""
		while [ $# -gt 1 ]; do
			[ "$1" = "-config" ] && { cfg="$2"; break; }
			shift
		done
		if [ -n "$cfg" ] && [ -r "$cfg" ] && grep -q '"outbounds"' "$cfg" \
			&& ! grep -q 'STUB_TEST_FAIL' "$cfg"; then
			echo "ok $cfg" >> "$LOG"; exit 0
		fi
		echo "fail ${cfg:-none}" >> "$LOG"; exit 1
		;;
	api)
		# F15: every api call is logged so override cases can assert on it,
		# and $STUB_BO_FAIL models the handler API failing outright
		echo "api $*" >> "${STUB_API_LOG:-/dev/null}"
		[ -f "${STUB_BO_FAIL:-/nonexistent}" ] && exit 1
		sub="$2"; shift 2
		# the non-flag args (values of `-t <s>`-style flags skipped too)
		args=""
		skipval=0
		for a in "$@"; do
			if [ "$skipval" = 1 ]; then skipval=0; continue; fi
			case "$a" in
				-t|-timeout) skipval=1 ;;
				-*) ;;
				*) args="$args $a" ;;
			esac
		done
		case "$sub" in
			statsquery)
				[ -f "${STUB_API_DOWN:-/nonexistent}" ] && exit 1
				exit 0
				;;
			lso)
				[ -f "${STUB_API_DOWN:-/nonexistent}" ] && exit 1
				first=1
				printf '{"outbounds":['
				while IFS= read -r t; do
					[ -n "$t" ] || continue
					[ "$first" = 1 ] || printf ','
					first=0
					printf '{"tag":"%s"}' "$t"
				done < "$OB"
				printf ']}\n'
				;;
			rmo)
				[ -f "${STUB_API_FAIL:-/nonexistent}" ] && exit 1
				for f in $args; do
					if [ -f "$f" ]; then
						tags=$(jsonfilter -i "$f" -e '@.outbounds[*].tag' 2>/dev/null)
					else
						tags="$f"
					fi
					for t in $tags; do
						grep -vx "$t" "$OB" > "$OB.tmp" 2>/dev/null
						mv "$OB.tmp" "$OB"
					done
				done
				exit 0
				;;
			ado)
				[ -f "${STUB_API_FAIL:-/nonexistent}" ] && exit 1
				# rmo already applied - models a batch that fails mid-mutation
				[ -f "${STUB_API_FAIL_ADO:-/nonexistent}" ] && exit 1
				for f in $args; do
					[ -f "$f" ] || exit 1
					for t in $(jsonfilter -i "$f" -e '@.outbounds[*].tag' 2>/dev/null); do
						if grep -qx "$t" "$OB" 2>/dev/null; then
							echo "failed to add outbound: existing tag found: $t" >&2
							exit 1
						fi
						echo "$t" >> "$OB"
					done
				done
				exit 0
				;;
		esac
		exit 0
		;;
	run)
		# tmpxray instance: pretend to serve until signalled. The real one
		# listens on the ports the netstat stub below claims.
		while :; do sleep 10; done
		;;
esac
exit 0
EOF
cat > "$SB/bin/pgrep" <<'EOF'
#!/bin/sh
# pgrep stub: xray "runs" unless the scenario flags it down ($STUB_PGREP_DOWN)
[ -f "${STUB_PGREP_DOWN:-/nonexistent}" ] && exit 1
exit 0
EOF
cat > "$SB/bin/uci" <<'EOF'
#!/bin/sh
# uci stub: keeps the sandbox off the live UCI. Hardcoded answers keep the
# deterministic cases stable: backup_keep=3 pins the prune budget, hot_swap
# defaults to 0 (pre-F14 assertions byte-stable, hot-swap cases opt in via
# $STUB_UCI_HOTSWAP), probe_disabled names the exit the e2e cases expect to be
# skipped, e2e_cron answers 1 only while $STUB_UCI_E2E_CRON is set (cron-sync
# case). Everything else is served from files in `uci show xray-monitor`
# format: $STUB_UCI first (the default answers only backup_keep=3; the F18
# fetch-via sections rewrite it with subscriptions and fetch_via* options),
# then $STUB_UCI_STATE (balancer_override sections for the F15 override
# cases). Nothing found = rc 1 / empty, so an empty sub list keeps the legacy
# "all proxy outbounds are managed" mode. Anything else (add/set/commit/...)
# fails like before.
while [ $# -gt 0 ]; do
	case "$1" in
		-q) ;;
		show)
			if [ -f "${STUB_UCI_STATE:-/nonexistent}" ]; then
				cat "${STUB_UCI_STATE}"
			else
				[ -n "${STUB_UCI:-}" ] && cat "$STUB_UCI" 2>/dev/null
			fi
			exit 0 ;;
		get)
			[ -n "$2" ] || exit 1
			case "$2" in
				xray-monitor.sub.backup_keep) echo 3; exit 0 ;;
				xray-monitor.sub.hot_swap) echo "${STUB_UCI_HOTSWAP:-0}"; exit 0 ;;
				xray-monitor.sub.probe_disabled) echo "e2e-skip"; exit 0 ;;
				xray-monitor.sub.e2e_cron)
					[ -n "${STUB_UCI_E2E_CRON:-}" ] && { echo 1; exit 0; }
					exit 1 ;;
			esac
			# fixed-prefix match via case (no regex: section ids carry
			# [ ] and dots that must not be interpreted)
			while IFS= read -r line; do
				case "$line" in "$2="*)
					v=${line#*=}; v=${v#\'}; v=${v%\'}
					echo "$v"; exit 0 ;;
				esac
			done < "${STUB_UCI:-/dev/null}"
			# generic "<section>.<option>='value'" lookup for the override
			# sections (the option name carries no dots, so this sed is safe)
			if [ -f "${STUB_UCI_STATE:-/nonexistent}" ]; then
				val=$(sed -n "s/^$(printf '%s' "$2" | sed 's/[.]/\\./g')='\\(.*\\)'$/\\1/p" "${STUB_UCI_STATE}")
				if [ -n "$val" ]; then echo "$val"; exit 0; fi
			fi
			exit 1 ;;
	esac
	shift
done
exit 1
EOF
cat > "$SB/bin/ubus" <<'EOF'
#!/bin/sh
# ubus stub: stands in for the rpcd outbounds surface consulted by the F18
# exit-selection fallback - $STUB_UBUS_OUT holds the (config-ordered) reply.
# Every invocation is logged so cases can assert whether the fallback ran.
echo "ubus $*" >> "${STUB_UBUS_LOG:-/dev/null}"
if [ "$1" = call ] && [ "$2" = xray-monitor ] && [ "$3" = outbounds ] && [ -r "${STUB_UBUS_OUT:-}" ]; then
	cat "$STUB_UBUS_OUT"
	exit 0
fi
exit 1
EOF
cat > "$SB/bin/curl" <<'EOF'
#!/bin/sh
# curl stub, two protocols in one binary (dispatch on -w: only the e2e
# runner passes a write-out format).
# e2e calls (F13): resolve the exit tag from the tmpxray state file's port
# map, then answer from $STUB_CURL_DIR/<tag>.204 or <tag>.body:
#   line 1: curl exit code (0 ok, 28 timeout mid-transfer, 7 connect fail, ...)
#   line 2: the -w line "http|ttfb_s|total_s|size_download|speed_download"
#   line 3: optional seconds to sleep first (simulates a slow/frozen exit)
# An unknown tag gets a resolve failure, like a dead socks port. Every
# e2e call is logged ("tag=... kind=... port=... ua=... url=...") so the
# scenario can prove a probe_disabled exit is never dialled.
# every other call (F18 fetch-via / self-update, and the plain fetches):
# logs the full argv (with a socks= marker so direct vs proxied calls are
# distinguishable), then answers from per-URL canned files so a whole
# self-update can run against it:
#   *.sha256  -> $STUB_CURL_SHA256     *.ipk -> $STUB_CURL_IPK
#   *Packages -> $STUB_CURL_PACKAGES   else  -> $STUB_CURL_BODY (fetch body)
# $STUB_CURL_HDR is copied into the -D header-dump file, keeping the
# subscription-userinfo capture in play on the proxy path too. Flags:
#   $STUB_CURL_FAIL_ALL     every call fails
#   $STUB_CURL_DIRECT_DOWN  calls WITHOUT --socks5-hostname fail (direct is
#                           down, the proxy works - the auto-mode retry case)
case " $* " in *" -w "*)
	LOG=${STUB_CURL_LOG:-/dev/null}
	DIR=${STUB_CURL_DIR:-/nonexistent}
	args="$*"
	port=$(printf '%s' "$args" | sed -n 's/.*--socks5-hostname 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p')
	url=$(printf '%s' "$args" | tr ' ' '\n' | grep -E '^https?://' | head -n 1)
	ua=$(printf '%s' "$args" | sed -n 's/.*-A \([^ ]*\).*/\1/p')
	kind=body
	case "$url" in *204*) kind=204 ;; esac
	tag=""
	if [ -n "$port" ] && [ -s "${STUB_TMPXRAY_STATE:-/nonexistent}" ]; then
		# "ports" content of the tmpxray state: strip the prefix up to the object,
		# then the outer closing brace, then everything from the ports' own brace
		ports=$(cat "${STUB_TMPXRAY_STATE}" 2>/dev/null)
		ports=${ports#*'"ports":{'}
		ports=${ports%\}}
		ports=${ports%%\}*}
		for pair in $(printf '%s' "$ports" | tr ',' '\n'); do
			if [ "$(printf '%s' "$pair" | cut -d':' -f2)" = "$port" ]; then
				tag=$(printf '%s' "$pair" | cut -d'"' -f2)
				break
			fi
		done
	fi
	echo "tag=$tag kind=$kind port=$port ua=$ua url=$url" >> "$LOG"
	f="$DIR/$tag.$kind"
	if [ -s "$f" ] && [ -n "$tag" ]; then
		rc=$(sed -n '1p' "$f")
		case "$rc" in ''|*[!0-9]*) rc=0 ;; esac
		sl=$(sed -n '3p' "$f")
		case "$sl" in ''|*[!0-9]*) sl=0 ;; esac
		[ "$sl" -gt 0 ] && sleep "$sl"
		sed -n '2p' "$f"
		exit "$rc"
	fi
	echo "000|0.000|0.000|0|0"
	exit 6
		;;
esac
case " $* " in *" --socks5-hostname "*) socks=1 ;; *) socks=0 ;; esac
echo "curl[socks=$socks] $*" >> "${STUB_CURL_LOG:-/dev/null}"
[ -f "${STUB_CURL_FAIL_ALL:-/nonexistent}" ] && exit 22
[ -f "${STUB_CURL_DIRECT_DOWN:-/nonexistent}" ] && [ "$socks" = 0 ] && exit 7
url=""
for a in "$@"; do
	case "$a" in http://*|https://*) url="$a" ;; esac
done
case "$url" in
	*.sha256)  body="${STUB_CURL_SHA256:-}" ;;
	*.ipk)     body="${STUB_CURL_IPK:-}" ;;
	*Packages) body="${STUB_CURL_PACKAGES:-}" ;;
	*)         body="${STUB_CURL_BODY:-}" ;;
esac
hdrs=""; out=""
while [ $# -gt 0 ]; do
	case "$1" in
		-D) hdrs="$2"; shift 2; continue ;;
		-o) out="$2"; shift 2; continue ;;
	esac
	shift
done
if [ -n "$hdrs" ] && [ -r "${STUB_CURL_HDR:-/nonexistent}" ]; then cp "$STUB_CURL_HDR" "$hdrs"; fi
if [ -n "$out" ]; then
	[ -r "$body" ] && cat "$body" > "$out"
else
	[ -r "$body" ] && cat "$body"
fi
exit 0
EOF

cat > "$SB/bin/opkg" <<'EOF'
#!/bin/sh
# opkg stub: even if a future case reaches self-update, nothing gets installed.
# Calls also mark the tmpxray log so the F18 cases can assert ordering (the
# proxied self-update must stop the instance BEFORE handing the file to opkg).
echo "opkg $*" >> "${STUB_OPKG_LOG:-/dev/null}"
echo "opkg-mark" >> "${STUB_TMPXRAY_LOG:-/dev/null}"
exit 0
EOF
cat > "$SB/bin/netstat" <<'EOF'
#!/bin/sh
# netstat stub: every port named by any sandboxed tmpxray config counts as
# listening. Both tmpxray_pick_ports (avoid busy ports) and tmpxray_wait_ports
# (wait for the bind) read this; the config exists before the instance is
# spawned, so "listening" appears the moment xray (stub) starts.
printf 'Active Internet connections (only servers)\n'
printf 'Proto Recv-Q Send-Q Local Address           Foreign Address         State\n'
for cfg in "${TMPDIR:-/tmp}"/tmpxray.*/config.json; do
	[ -r "$cfg" ] || continue
	for p in $(jsonfilter -i "$cfg" -e '@.inbounds[*].port' 2>/dev/null); do
		printf 'tcp        0      0 127.0.0.1:%-20d 0.0.0.0:*               LISTEN\n' "$p"
	done
done
exit 0
EOF
cat > "$SB/etc/init.d/xray" <<'EOF'
#!/bin/sh
# init script stub: records what it was asked to do instead of restarting xray
echo "$*" >> "${STUB_INITD_LOG:-/dev/null}"
exit 0
EOF
cp "$SB/etc/init.d/xray" "$SB/etc/init.d/cron"
chmod 0755 "$SB/bin/xray" "$SB/bin/pgrep" "$SB/bin/uci" "$SB/bin/opkg" \
	"$SB/bin/netstat" "$SB/bin/ubus" "$SB/bin/curl" \
	"$SB/etc/init.d/xray" "$SB/etc/init.d/cron" "$SB/sub"
touch "$SB/lock/xray-monitor"

export TMPDIR="$SB/tmp"
export STUB_LOG="$SB/log/xray-test.log"
export STUB_HOOK_LOG="$SB/log/hooks.log"
export STUB_INITD_LOG="$SB/log/initd.log"
export STUB_PGREP_DOWN="$SB/flags/xray-down"
export STUB_OPKG_LOG="$SB/log/opkg.log"
export STUB_API_OB="$SB/api/ob.tags"
export STUB_API_DOWN="$SB/flags/api-down"
export STUB_API_FAIL="$SB/flags/api-fail"
export STUB_API_FAIL_ADO="$SB/flags/api-fail-ado"
# F15: api-call log of the xray stub, its bo-failure flag, and the uci state
# file the override cases fill in (absent until then = no overrides)
export STUB_API_LOG="$SB/log/api.log"
export STUB_BO_FAIL="$SB/flags/bo-fail"
export STUB_UCI_STATE="$SB/work/uci-state"
# F13: curl stub table + log, tmpxray state file location
export STUB_CURL_DIR="$SB/curltab"
export STUB_CURL_LOG="$SB/log/curl.log"
export STUB_TMPXRAY_STATE="$SB/tmp/xray-monitor/tmpxray.json"
# F18 fetch-via plumbing: uci answers come from a file, ubus serves the rpcd
# outbounds surface, curl/tmpxray log their calls, and the failure flags let
# individual cases take the proxy down.
export STUB_UCI="$SB/work/uci-show.txt"
export STUB_UBUS_LOG="$SB/log/ubus.log"
export STUB_UBUS_OUT="$SB/work/ubus-outbounds.json"
export STUB_CURL_BODY="$FIX/sub1.json"
export STUB_CURL_HDR="$SB/work/curl-hdrs.txt"
export STUB_CURL_IPK="$SB/work/fake-update.ipk"
export STUB_CURL_SHA256="$SB/work/fake-update.sha256"
export STUB_CURL_PACKAGES="$SB/work/fake-Packages"
export STUB_TMPXRAY_LOG="$SB/log/tmpxray.log"
export STUB_TMPXRAY_FAIL="$SB/flags/tmpxray-fail"
export STUB_CURL_FAIL_ALL="$SB/flags/curl-fail-all"
export STUB_CURL_DIRECT_DOWN="$SB/flags/curl-direct-down"
mkdir -p "$SB/api"
: > "$STUB_LOG"; : > "$STUB_HOOK_LOG"; : > "$STUB_INITD_LOG"; : > "$STUB_OPKG_LOG"; : > "$STUB_API_OB"; : > "$STUB_API_LOG"
: > "$STUB_UBUS_LOG"; : > "$STUB_CURL_LOG"; : > "$STUB_TMPXRAY_LOG"
rm -f "$STUB_BO_FAIL" "$STUB_UCI_STATE"
# default uci answers = the old hardcoded stub: only backup_keep, no subs
printf '%s\n' "xray-monitor.sub=xray-monitor" "xray-monitor.sub.backup_keep='3'" > "$STUB_UCI"
# canned HTTP response headers for the fetch cases (subscription-userinfo must
# survive the proxy path - store_usage parses it from the -D dump file)
printf 'HTTP/1.1 200 OK\r\nsubscription-userinfo: upload=0; download=1234; total=5678; expire=0\r\n' > "$STUB_CURL_HDR"
# a self-update payload the stub curl can serve: a real gzip tar (tar -tzf must
# accept it) plus its correct .sha256 sidecar
mkdir -p "$SB/work/fake-pkg"
echo "scenario fake package payload" > "$SB/work/fake-pkg/data.txt"
tar -czf "$STUB_CURL_IPK" -C "$SB/work/fake-pkg" . 2>/dev/null
sha=$(sha256sum "$STUB_CURL_IPK" 2>/dev/null | awk '{ print $1 }')
printf '%s  luci-app-xray-monitor.ipk\n' "$sha" > "$STUB_CURL_SHA256"
printf 'Package: luci-app-xray-monitor\nVersion: 9.9.9-1\nFilename: luci-app-xray-monitor.ipk\nSHA256sum: %s\n' "$sha" > "$STUB_CURL_PACKAGES"

CFG="$SB/etc/xray/config.json"
fails=0

pass() { echo "PASS   $1"; }
fail() { echo "FAIL   $1"; fails=$((fails + 1)); }
ok_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: want [$2] got [$3]"; fi; }
is()    { if [ "$2" = 1 ]; then pass "$1"; else fail "$1"; fi; }
same()  { if cmp -s "$1" "$2"; then echo 1; else echo 0; fi; }
differs() { if cmp -s "$1" "$2"; then echo 0; else echo 1; fi; }

runsub()    { PATH="$SB/bin:$PATH" sh "$SB/sub" "$@"; }
runsub_nw() { XRAYMON_NOWAIT=1 PATH="$SB/bin:$PATH" sh "$SB/sub" "$@"; }
lines()     { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
restarts()  { lines "$STUB_INITD_LOG"; }
hookruns()  { lines "$STUB_HOOK_LOG"; }
baks()      { ls "$CFG".bak.* 2>/dev/null | wc -l | tr -d ' '; }
last_test() { tail -n 1 "$STUB_LOG" | cut -d' ' -f1; }
# newest backup of a kind: names embed the timestamp, so plain ls sorts by age
auto_bak()   { ls "$CFG".bak.* 2>/dev/null | grep -E '\.bak\.[0-9]{8}-[0-9]{6}$' | tail -n 1; }
manual_bak() { ls "$CFG".bak.manual.* 2>/dev/null | tail -n 1; }
preapi_bak() { ls "$CFG".bak.preapi.* 2>/dev/null | tail -n 1; }
# running-xray model (F14): the lso/rmo/ado stub state == the installed config
api_sync() { jsonfilter -i "$CFG" -e '@.outbounds[*].tag' 2>/dev/null | sed '/^$/d' > "$STUB_API_OB"; }
api_same_as_cfg() { [ "$(sort -u < "$STUB_API_OB")" = "$(jsonfilter -i "$CFG" -e '@.outbounds[*].tag' 2>/dev/null | sed '/^$/d' | sort -u)" ]; }
la_get() { jsonfilter -i "$SB/state/last-apply.json" -e "$1" 2>/dev/null; }

touch -t 202001010000 "$SB/tmp/.tprobe" 2>/dev/null && TOUCH_T=1 || TOUCH_T=0
rm -f "$SB/tmp/.tprobe"
[ "$TOUCH_T" = 1 ] || echo "NOTE   touch -t unavailable - prune assertions skipped"

reset_cfg() {  # live config = fixture, no backups, no half-installed candidate
	cp "$FIX/config.json" "$CFG"
	rm -f "$CFG".bak.* "$CFG.new"
}
seed_baks() {  # <n> aged-out backups prune_backups must drop first
	# pipeline-shaped names (trailing timestamp): prune_backups only manages
	# backups it recognizes - strays are covered by the apply section below
	i=0
	while [ "$i" -lt "$1" ]; do
		i=$((i + 1))
		cp "$CFG" "$CFG.bak.20200101-00000$i"
		[ "$TOUCH_T" = 1 ] && touch -t 202001010000 "$CFG.bak.20200101-00000$i"
	done
}

echo "== apply: auto backup, candidate tested + installed, restart, hooks, prune"
reset_cfg
seed_baks 5
# a stray, non-pipeline backup: prune must neither count nor ever delete it
cp "$CFG" "$CFG.bak.not-pipeline"
[ "$TOUCH_T" = 1 ] && touch -t 202001010000 "$CFG.bak.not-pipeline"
cp "$CFG" "$SB/work/pre-apply.json"
cp "$FIX/staged-clean.json" "$SB/state/staged.json"
# expected installed content = the very transform the copy runs (no prefixes:
# uci stub) - computed twice to prove it is deterministic
"$SB/share/xray-monitor/apply.uc" "$CFG" "$SB/state/staged.json" "$SB/work/exp1.json" >/dev/null 2>&1
"$SB/share/xray-monitor/apply.uc" "$CFG" "$SB/state/staged.json" "$SB/work/exp2.json" >/dev/null 2>&1
is "apply.uc produced the expected output" "$([ -s "$SB/work/exp1.json" ] && echo 1 || echo 0)"
is "apply.uc deterministic" "$(same "$SB/work/exp1.json" "$SB/work/exp2.json")"
r0=$(restarts); h0=$(hookruns)
out=$(runsub apply 2>/dev/null); rc=$?
ok_eq "apply: stdout" "ok" "$out"
ok_eq "apply: rc" 0 "$rc"
ab=$(auto_bak)
is "apply: auto-named backup (no kind word)" "$([ -n "$ab" ] && echo 1 || echo 0)"
is "apply: backup holds the pre-change config" "$(same "$ab" "$SB/work/pre-apply.json")"
ok_eq "apply: candidate passed xray -test" "ok" "$(last_test)"
is "apply: candidate installed verbatim" "$(same "$CFG" "$SB/work/exp1.json")"
is "apply: atomic rename left no \$CFG.new" "$([ ! -e "$CFG.new" ] && echo 1 || echo 0)"
ok_eq "apply: restart invoked once" "$((r0 + 1))" "$(restarts)"
ok_eq "apply: post_restart_hooks ran" "$((h0 + 1))" "$(hookruns)"
[ "$TOUCH_T" = 1 ] && ok_eq "apply: prune kept 3 backups + the stray" 4 "$(baks)"
[ "$TOUCH_T" = 1 ] && is "apply: non-pipeline stray survived prune" "$([ -f "$CFG.bak.not-pipeline" ] && echo 1 || echo 0)"
ok_eq "apply: status=applied pending=0" "applied 0" "$(cat "$SB/state/status" 2>/dev/null) $(cat "$SB/state/pending" 2>/dev/null)"

echo "== routing-set / balancers-set: same pipeline through the shared function"
for cmd in routing-set balancers-set; do
	reset_cfg
	case "$cmd" in routing-set) inp="$FIX/routing-desired.json" ;; *) inp="$FIX/balancers-desired.json" ;; esac
	cp "$CFG" "$SB/work/pre-$cmd.json"
	r0=$(restarts); h0=$(hookruns)
	out=$(runsub "$cmd" "$inp" 2>/dev/null); rc=$?
	ok_eq "$cmd: stdout" "ok" "$out"
	ok_eq "$cmd: rc" 0 "$rc"
	ab=$(auto_bak)
	is "$cmd: auto-named backup" "$([ -n "$ab" ] && echo 1 || echo 0)"
	is "$cmd: backup holds the pre-change config" "$(same "$ab" "$SB/work/pre-$cmd.json")"
	ok_eq "$cmd: candidate passed xray -test" "ok" "$(last_test)"
	is "$cmd: installed config differs from the old one" "$(differs "$CFG" "$SB/work/pre-$cmd.json")"
	is "$cmd: no leftover \$CFG.new" "$([ ! -e "$CFG.new" ] && echo 1 || echo 0)"
	ok_eq "$cmd: restart invoked once" "$((r0 + 1))" "$(restarts)"
	ok_eq "$cmd: post_restart_hooks ran" "$((h0 + 1))" "$(hookruns)"
done

echo "== config-save: manual-kind backup, uploaded file installed as-is"
reset_cfg
cp "$CFG" "$SB/work/pre-save.json"
cp "$FIX/staged-clean.json" "$SB/work/save-in.json"
r0=$(restarts); h0=$(hookruns)
out=$(runsub config-save "$SB/work/save-in.json" 2>/dev/null); rc=$?
ok_eq "config-save: stdout" "saved and restarted xray" "$out"
ok_eq "config-save: rc" 0 "$rc"
mb=$(manual_bak)
is "config-save: manual backup" "$([ -n "$mb" ] && echo 1 || echo 0)"
is "config-save: backup holds the pre-change config" "$(same "$mb" "$SB/work/pre-save.json")"
ok_eq "config-save: candidate passed xray -test" "ok" "$(last_test)"
is "config-save: uploaded file installed verbatim" "$(same "$CFG" "$SB/work/save-in.json")"
ok_eq "config-save: restart invoked once" "$((r0 + 1))" "$(restarts)"
ok_eq "config-save: post_restart_hooks ran" "$((h0 + 1))" "$(hookruns)"

echo "== enable-api: preapi-kind backup, stats API required by verify"
reset_cfg
cp "$CFG" "$SB/work/pre-api.json"
r0=$(restarts); h0=$(hookruns)
out=$(runsub enable-api 2>/dev/null); rc=$?
ok_eq "enable-api: stdout" "enabled and restarted xray ($CFG)" "$out"
ok_eq "enable-api: rc" 0 "$rc"
pb=$(preapi_bak)
is "enable-api: preapi backup" "$([ -n "$pb" ] && echo 1 || echo 0)"
is "enable-api: backup holds the pre-change config" "$(same "$pb" "$SB/work/pre-api.json")"
is "enable-api: merged config has StatsService" "$(grep -q StatsService "$CFG" && echo 1 || echo 0)"
ok_eq "enable-api: restart invoked once" "$((r0 + 1))" "$(restarts)"
ok_eq "enable-api: post_restart_hooks ran" "$((h0 + 1))" "$(hookruns)"

echo "== prune failure: an undeletable old backup must not fail the write"
if [ "$TOUCH_T" = 1 ]; then
	reset_cfg
	# 3 deletable old backups plus a directory with the oldest mtime: prune
	# keeps the 3 newest, rm(1) cannot remove the directory and fails last.
	# Pipeline-shaped names, or prune_backups would (rightly) skip them all.
	mkdir -p "$CFG.bak.20200101-000000"
	touch -t 202001010000 "$CFG.bak.20200101-000000"
	i=1
	while [ "$i" -le 3 ]; do
		cp "$CFG" "$CFG.bak.20200101-00001$i"
		touch -t 20200101010$i "$CFG.bak.20200101-00001$i"
		i=$((i + 1))
	done
	cp "$CFG" "$SB/work/pre-prune.json"
	cp "$FIX/staged-clean.json" "$SB/state/staged.json"
	out=$(runsub apply 2>/dev/null); rc=$?
	ok_eq "prune-failure: stdout still ok" "ok" "$out"
	ok_eq "prune-failure: rc still 0" 0 "$rc"
	ok_eq "prune-failure: status still applied" "applied" "$(cat "$SB/state/status" 2>/dev/null)"
	is "prune-failure: candidate installed anyway" "$(differs "$CFG" "$SB/work/pre-prune.json")"
	is "prune-failure: rm really failed (directory kept)" "$([ -d "$CFG.bak.20200101-000000" ] && echo 1 || echo 0)"
	is "prune-failure: prune did run (deletable aged backup gone)" "$([ ! -e "$CFG.bak.20200101-000011" ] && echo 1 || echo 0)"
	rm -rf "$CFG.bak.20200101-000000"
else
	echo "NOTE   touch -t unavailable - prune-failure case skipped"
fi

echo "== test-failed: a rejected candidate leaves the live config alone"
reset_cfg
cp "$CFG" "$SB/work/pre-fail.json"
printf '{"outbounds":[]}\nSTUB_TEST_FAIL\n' > "$SB/work/bad.json"
r0=$(restarts); h0=$(hookruns); b0=$(baks)
out=$(runsub config-save "$SB/work/bad.json" 2>/dev/null); rc=$?
ok_eq "test-failed: stdout" "xray -test failed; not saved" "$out"
ok_eq "test-failed: rc" 1 "$rc"
is "test-failed: live config untouched" "$(same "$CFG" "$SB/work/pre-fail.json")"
ok_eq "test-failed: last xray -test verdict" "fail" "$(last_test)"
is "test-failed: no leftover \$CFG.new" "$([ ! -e "$CFG.new" ] && echo 1 || echo 0)"
ok_eq "test-failed: no restart" "$r0" "$(restarts)"
ok_eq "test-failed: no hooks" "$h0" "$(hookruns)"
ok_eq "test-failed: no backup left (validated before the snapshot)" "$b0" "$(baks)"

echo "== verify-failed: xray does not come back -> rollback restores the snapshot"
reset_cfg
cp "$CFG" "$SB/work/pre-rb.json"
touch "$STUB_PGREP_DOWN"
r0=$(restarts); h0=$(hookruns)
out=$(runsub routing-set "$FIX/routing-desired.json" 2>/dev/null); rc=$?
ok_eq "verify-failed(routing-set): stdout" "xray/api failed health check - rolled back" "$out"
ok_eq "verify-failed(routing-set): rc" 1 "$rc"
is "verify-failed: snapshot restored over the bad config" "$(same "$CFG" "$SB/work/pre-rb.json")"
ok_eq "verify-failed: restart tried twice (install + rollback)" "$((r0 + 2))" "$(restarts)"
ok_eq "verify-failed: no hooks" "$h0" "$(hookruns)"

out=$(runsub apply 2>/dev/null); rc=$?
ok_eq "verify-failed(apply): stdout" "applied but xray/api failed health check - rolled back" "$out"
ok_eq "verify-failed(apply): rc" 1 "$rc"
ok_eq "verify-failed(apply): status file" "rolled-back" "$(cat "$SB/state/status" 2>/dev/null)"
is "verify-failed(apply): snapshot restored" "$(same "$CFG" "$SB/work/pre-rb.json")"
rm -f "$STUB_PGREP_DOWN"

echo "== symlinked config.json: snapshot dereferences, rollback restores through the link"
# The live config is a symlink to a real file (set-cfg can point xray at one).
# The snapshot MUST be a regular file with the OLD content - `cp -a` would
# copy the link itself, so after the install the "backup" would already hold
# the NEW config and the rollback below would restore nothing.
REAL="$SB/etc/xray/config.real.json"
rm -f "$CFG" "$CFG".bak.* "$CFG.new" "$REAL" "$REAL.new"
cp "$FIX/config.json" "$REAL"
ln -s "$REAL" "$CFG"
cp "$FIX/staged-clean.json" "$SB/state/staged.json"
cp "$REAL" "$SB/work/pre-sym.json"
is "symlink: the staged change really differs from the old config" "$(differs "$SB/work/exp1.json" "$SB/work/pre-sym.json")"
touch "$STUB_PGREP_DOWN"
r0=$(restarts)
out=$(runsub apply 2>/dev/null); rc=$?
ok_eq "symlink(apply): stdout" "applied but xray/api failed health check - rolled back" "$out"
ok_eq "symlink(apply): rc" 1 "$rc"
ab=$(auto_bak)
is "symlink: snapshot is a regular file, not a symlink into the live config" "$([ -f "$ab" ] && [ ! -L "$ab" ] && echo 1 || echo 0)"
is "symlink: snapshot holds the OLD config" "$(same "$ab" "$SB/work/pre-sym.json")"
is "symlink: OLD content back through the link after rollback" "$(same "$CFG" "$SB/work/pre-sym.json")"
is "symlink: config.json is still a symlink" "$([ -L "$CFG" ] && echo 1 || echo 0)"
is "symlink: no leftover .new beside the real file" "$([ ! -e "$REAL.new" ] && echo 1 || echo 0)"
ok_eq "symlink: restart tried twice (install + rollback)" "$((r0 + 2))" "$(restarts)"
rm -f "$STUB_PGREP_DOWN"
# a successful write through a symlink, too: the link must survive it
rm -f "$CFG".bak.*
cp "$REAL" "$SB/work/pre-sym2.json"
out=$(runsub apply 2>/dev/null); rc=$?
ok_eq "symlink(apply,healthy): stdout" "ok" "$out"
ok_eq "symlink(apply,healthy): rc" 0 "$rc"
is "symlink(healthy): new config installed through the link" "$(same "$CFG" "$SB/work/exp1.json")"
is "symlink(healthy): config.json is still a symlink" "$([ -L "$CFG" ] && echo 1 || echo 0)"
# back to a plain file for the sections below
rm -f "$CFG" "$CFG".bak.* "$REAL" "$REAL.new"
cp "$FIX/config.json" "$CFG"

echo "== F15 overrides: a restart-triggering command re-applies the sticky pins"
reset_cfg
cat > "$STUB_UCI_STATE" <<'EOV'
xray-monitor.cfg03d1=balancer_override
xray-monitor.cfg03d1.balancer='any-balancer'
xray-monitor.cfg03d1.outbound='proxy-ch'
xray-monitor.cfg04a2=balancer_override
xray-monitor.cfg04a2.balancer='ghost-balancer'
xray-monitor.cfg04a2.outbound='proxy-fi'
EOV
exp=$(printf '[\n{"balancer":"any-balancer","outbound":"proxy-ch"},\n{"balancer":"ghost-balancer","outbound":"proxy-fi"}\n]')
out=$(runsub overrides-list 2>/dev/null)
ok_eq "overrides-list: JSON of every balancer_override section" "$exp" "$out"
: > "$STUB_API_LOG"
r0=$(restarts); h0=$(hookruns)
out=$(runsub config-save "$FIX/config.json" 2>/dev/null); rc=$?
ok_eq "hook(config-save): stdout still exactly the writer's message" "saved and restarted xray" "$out"
ok_eq "hook(config-save): rc" 0 "$rc"
ok_eq "hook: post_restart_hooks ran" "$((h0 + 1))" "$(hookruns)"
ok_eq "hook: bo called once (the stale section is skipped)" 1 "$(grep -c ' bo ' "$STUB_API_LOG" 2>/dev/null)"
is "hook: bo carries the persisted balancer+outbound" "$(grep -q -- '-b any-balancer proxy-ch' "$STUB_API_LOG" && echo 1 || echo 0)"
is "hook: stale override never sent to the api" "$(grep -q 'ghost-balancer' "$STUB_API_LOG" && echo 0 || echo 1)"

echo "== overrides-apply: on-demand re-apply (and its failure path)"
: > "$STUB_API_LOG"
out=$(runsub overrides-apply 2>/dev/null); rc=$?
ok_eq "overrides-apply: stdout" "ok - applied 1 override(s), skipped 1 (balancer not in config)" "$out"
ok_eq "overrides-apply: rc" 0 "$rc"
ok_eq "overrides-apply: one bo call" 1 "$(grep -c ' bo ' "$STUB_API_LOG" 2>/dev/null)"
touch "$STUB_BO_FAIL"
: > "$STUB_API_LOG"
out=$(runsub overrides-apply 2>/dev/null); rc=$?
ok_eq "overrides-apply(failing bo): rc" 1 "$rc"
ok_eq "overrides-apply(failing bo): message names the failed balancer" "applied 0, failed: any-balancer" "$out"
rm -f "$STUB_BO_FAIL"
rm -f "$STUB_UCI_STATE"

echo "== no-restart: test + backup + atomic install, no restart / verify / hooks / prune"
reset_cfg
seed_baks 5
cp "$CFG" "$SB/work/pre-nr.json"
cp "$FIX/config.json" "$SB/work/nr-cand.json"
echo '// no-restart candidate' >> "$SB/work/nr-cand.json"
# commit_config is pipeline-internal (no CLI command uses no-restart yet), so
# drive it directly: the sandboxed copy's definitions (everything before the
# command dispatcher) plus a small driver script.
sed -n '/^case "\$1" in/q;p' "$SB/sub" > "$SB/lib.sh"
grep -q '^commit_config()' "$SB/lib.sh" || { echo "scenario setup failed: commit_config not in lib part"; exit 1; }
cat > "$SB/work/nr-driver.sh" <<EOF
stage_init
cp "$SB/work/nr-cand.json" "\$STAGE_DIR/config.json"
commit_config "" 0 "\$STAGE_DIR/config.json" no-restart
echo "rc=\$?"
echo "bak=\$COMMIT_BAK"
EOF
cat "$SB/lib.sh" "$SB/work/nr-driver.sh" > "$SB/work/nr-run.sh"
r0=$(restarts); h0=$(hookruns)
nr=$(PATH="$SB/bin:$PATH" sh "$SB/work/nr-run.sh" 2>/dev/null); nrc=$?
ok_eq "no-restart: driver rc" 0 "$nrc"
ok_eq "no-restart: commit_config rc=0" 0 "$(printf '%s\n' "$nr" | sed -n 's/^rc=//p')"
nrbak=$(printf '%s\n' "$nr" | sed -n 's/^bak=//p')
is "no-restart: snapshot path reported in \$COMMIT_BAK" "$([ -n "$nrbak" ] && echo 1 || echo 0)"
is "no-restart: snapshot exists and holds the pre-change config" \
	"$([ -f "$nrbak" ] && same "$nrbak" "$SB/work/pre-nr.json" || echo 0)"
ok_eq "no-restart: candidate passed xray -test" "ok" "$(last_test)"
is "no-restart: candidate installed" "$(same "$CFG" "$SB/work/nr-cand.json")"
is "no-restart: no leftover \$CFG.new" "$([ ! -e "$CFG.new" ] && echo 1 || echo 0)"
ok_eq "no-restart: no restart issued" "$r0" "$(restarts)"
ok_eq "no-restart: no hooks" "$h0" "$(hookruns)"
[ "$TOUCH_T" = 1 ] && ok_eq "no-restart: prune skipped (6 backups kept)" 6 "$(baks)"

printf '{"outbounds":[]}\nSTUB_TEST_FAIL\n' > "$SB/work/nr-bad.json"
cat > "$SB/work/nrbad-driver.sh" <<EOF
COMMIT_BAK="stale-from-a-previous-call"
stage_init
cp "$SB/work/nr-bad.json" "\$STAGE_DIR/config.json"
commit_config "" 0 "\$STAGE_DIR/config.json" no-restart
echo "rc=\$?"
echo "bak=[\$COMMIT_BAK]"
EOF
cat "$SB/lib.sh" "$SB/work/nrbad-driver.sh" > "$SB/work/nrbad-run.sh"
nb0=$(baks)
nr2=$(PATH="$SB/bin:$PATH" sh "$SB/work/nrbad-run.sh" 2>/dev/null); nr2rc=$?
ok_eq "no-restart(bad candidate): commit_config rc=1" 1 "$(printf '%s\n' "$nr2" | sed -n 's/^rc=//p')"
ok_eq "no-restart(bad candidate): driver rc" 0 "$nr2rc"
ok_eq "no-restart(bad candidate): \$COMMIT_BAK empty (reset per call)" "bak=[]" \
	"$(printf '%s\n' "$nr2" | grep '^bak=')"
ok_eq "no-restart(bad candidate): no snapshot left behind" "$nb0" "$(baks)"
ok_eq "no-restart(bad candidate): last xray -test verdict" "fail" "$(last_test)"
is "no-restart(bad candidate): live config untouched" "$(same "$CFG" "$SB/work/nr-cand.json")"

echo "== no-restart + fallback: the documented F14 recipe (restore + restart + verify)"
reset_cfg
cat > "$SB/work/fb-driver.sh" <<EOF
stage_init
cp "$SB/work/nr-cand.json" "\$STAGE_DIR/config.json"
commit_config "" 1 "\$STAGE_DIR/config.json" no-restart || { echo "install_rc=\$?"; exit 1; }
# simulated hot-swap failure -> fall back to a full restart + verify
# (restore via install_config: a plain cp would clobber a symlinked config)
install_config "\$COMMIT_BAK"
"$SB/etc/init.d/xray" restart >/dev/null 2>&1
verify_or_rollback "\$COMMIT_BAK" 1
echo "fallback_rc=\$?"
EOF
cat "$SB/lib.sh" "$SB/work/fb-driver.sh" > "$SB/work/fb-run.sh"
fb=$(PATH="$SB/bin:$PATH" sh "$SB/work/fb-run.sh" 2>/dev/null); fbrc=$?
ok_eq "fallback: driver rc" 0 "$fbrc"
ok_eq "fallback: restore + restart + verify healthy" 0 "$(printf '%s\n' "$fb" | sed -n 's/^fallback_rc=//p')"
is "fallback: config back to the snapshot" "$(same "$CFG" "$FIX/config.json")"

echo "== hot-swap (F14): outbound-only apply reconciles live via xray api rmo/ado"
# hs-staged.json vs config.json (legacy mode, uci stub): proxy-fi body changed,
# proxy-de added, proxy-ch dropped, manual-vps carried unchanged - a pure
# managed-outbound change whose first tag is re-added -> live, no restart.
reset_cfg
rm -f "$SB/state/last-apply.json"
api_sync
cp "$CFG" "$SB/work/pre-hs.json"
cp "$FIX/hs-staged.json" "$SB/state/staged.json"
r0=$(restarts); h0=$(hookruns)
STUB_UCI_HOTSWAP=1; export STUB_UCI_HOTSWAP
out=$(runsub apply 2>/dev/null); rc=$?
unset STUB_UCI_HOTSWAP
ok_eq "hot-swap(live): stdout" "ok (applied live)" "$out"
ok_eq "hot-swap(live): rc" 0 "$rc"
ok_eq "hot-swap(live): NO restart issued" "$r0" "$(restarts)"
ok_eq "hot-swap(live): no post_restart_hooks (no-restart mode)" "$h0" "$(hookruns)"
is "hot-swap(live): candidate installed" "$(differs "$CFG" "$SB/work/pre-hs.json")"
is "hot-swap(live): running set now equals the candidate" "$(api_same_as_cfg && echo 1 || echo 0)"
ab=$(auto_bak)
is "hot-swap(live): snapshot taken before the install" "$([ -n "$ab" ] && same "$ab" "$SB/work/pre-hs.json" || echo 0)"
ok_eq "hot-swap(live): status=applied pending=0" "applied 0" "$(cat "$SB/state/status" 2>/dev/null) $(cat "$SB/state/pending" 2>/dev/null)"
ok_eq "hot-swap(live): last-apply mode" "live" "$(la_get '@.mode')"
ok_eq "hot-swap(live): last-apply removed/added" "2 2" "$(la_get '@.removed') $(la_get '@.added')"
ok_eq "hot-swap(live): last-apply reason empty" "" "$(la_get '@.reason')"

echo "== hot-swap: churn-only staged state -> live with zero API mutations"
# hs-staged-churn.json carries every managed outbound (legacy mode includes
# manual-vps) with bodies equal after the ignore list - nothing to rmo/ado.
reset_cfg
api_sync
cp "$STUB_API_OB" "$SB/work/ob-before.tags"
cp "$FIX/hs-staged-churn.json" "$SB/state/staged.json"
r0=$(restarts)
STUB_UCI_HOTSWAP=1; export STUB_UCI_HOTSWAP
out=$(runsub apply 2>/dev/null); rc=$?
unset STUB_UCI_HOTSWAP
ok_eq "hot-swap(churn): stdout" "ok (applied live)" "$out"
ok_eq "hot-swap(churn): rc" 0 "$rc"
ok_eq "hot-swap(churn): no restart" "$r0" "$(restarts)"
ok_eq "hot-swap(churn): nothing removed/added" "0 0" "$(la_get '@.removed') $(la_get '@.added')"
is "hot-swap(churn): running set untouched" "$(same "$STUB_API_OB" "$SB/work/ob-before.tags")"

echo "== hot-swap: running set != config.json -> restart, reason recorded"
reset_cfg
api_sync
echo "ghost-tag" >> "$STUB_API_OB"
cp "$CFG" "$SB/work/pre-mm.json"
cp "$FIX/hs-staged.json" "$SB/state/staged.json"
r0=$(restarts); h0=$(hookruns)
STUB_UCI_HOTSWAP=1; export STUB_UCI_HOTSWAP
out=$(runsub apply 2>/dev/null); rc=$?
unset STUB_UCI_HOTSWAP
ok_eq "hot-swap(mismatch): stdout ok (restart path)" "ok" "$out"
ok_eq "hot-swap(mismatch): rc" 0 "$rc"
ok_eq "hot-swap(mismatch): restart invoked once" "$((r0 + 1))" "$(restarts)"
ok_eq "hot-swap(mismatch): hooks ran (restart path)" "$((h0 + 1))" "$(hookruns)"
is "hot-swap(mismatch): candidate installed" "$(differs "$CFG" "$SB/work/pre-mm.json")"
ok_eq "hot-swap(mismatch): last-apply mode/reason" "restart running-state-mismatch" "$(la_get '@.mode') $(la_get '@.reason')"
api_sync

echo "== hot-swap: handler API down -> restart, reason api-unavailable"
reset_cfg
api_sync
cp "$FIX/hs-staged.json" "$SB/state/staged.json"
r0=$(restarts)
touch "$STUB_API_DOWN"
STUB_UCI_HOTSWAP=1; export STUB_UCI_HOTSWAP
out=$(runsub apply 2>/dev/null); rc=$?
unset STUB_UCI_HOTSWAP
rm -f "$STUB_API_DOWN"
ok_eq "hot-swap(api-down): stdout ok (restart path)" "ok" "$out"
ok_eq "hot-swap(api-down): rc" 0 "$rc"
ok_eq "hot-swap(api-down): restart invoked once" "$((r0 + 1))" "$(restarts)"
ok_eq "hot-swap(api-down): last-apply mode/reason" "restart api-unavailable" "$(la_get '@.mode') $(la_get '@.reason')"

echo "== hot-swap: failing live step -> fallback restore + restart + verify"
reset_cfg
api_sync
cp "$CFG" "$SB/work/pre-fb2.json"
cp "$FIX/hs-staged.json" "$SB/state/staged.json"
r0=$(restarts); h0=$(hookruns)
touch "$STUB_API_FAIL"
STUB_UCI_HOTSWAP=1; export STUB_UCI_HOTSWAP
out=$(runsub apply 2>/dev/null); rc=$?
unset STUB_UCI_HOTSWAP
rm -f "$STUB_API_FAIL"
ok_eq "hot-swap(fallback): stdout" "hot-swap failed - rolled back to the previous config and restarted xray" "$out"
ok_eq "hot-swap(fallback): rc" 1 "$rc"
ok_eq "hot-swap(fallback): restart invoked once (rollback)" "$((r0 + 1))" "$(restarts)"
ok_eq "hot-swap(fallback): no hooks (rollback, not a healthy apply)" "$h0" "$(hookruns)"
is "hot-swap(fallback): snapshot restored over the candidate" "$(same "$CFG" "$SB/work/pre-fb2.json")"
ok_eq "hot-swap(fallback): status" "rolled-back" "$(cat "$SB/state/status" 2>/dev/null)"
ok_eq "hot-swap(fallback): last-apply mode/reason/fallback" "restart hot-swap-failed 1" "$(la_get '@.mode') $(la_get '@.reason') $(la_get '@.fallback')"
is "hot-swap(fallback): running set back to the restored config" "$(api_same_as_cfg && echo 1 || echo 0)"
api_sync

echo "== hot-swap: rmo applied but ado fails -> fallback from a MID-MUTATED running set"
reset_cfg
api_sync
cp "$CFG" "$SB/work/pre-fb3.json"
cp "$FIX/hs-staged.json" "$SB/state/staged.json"
r0=$(restarts)
touch "$STUB_API_FAIL_ADO"
STUB_UCI_HOTSWAP=1; export STUB_UCI_HOTSWAP
out=$(runsub apply 2>/dev/null); rc=$?
unset STUB_UCI_HOTSWAP
rm -f "$STUB_API_FAIL_ADO"
ok_eq "hot-swap(ado-fail): stdout" "hot-swap failed - rolled back to the previous config and restarted xray" "$out"
ok_eq "hot-swap(ado-fail): rc" 1 "$rc"
ok_eq "hot-swap(ado-fail): restart invoked once (rollback)" "$((r0 + 1))" "$(restarts)"
is "hot-swap(ado-fail): rmo HAD applied before ado failed (mid-mutation)" \
	"$(grep -qx manual-vps "$STUB_API_OB" && ! grep -qx proxy-fi "$STUB_API_OB" && ! grep -qx proxy-ch "$STUB_API_OB" && echo 1 || echo 0)"
is "hot-swap(ado-fail): snapshot restored over the candidate" "$(same "$CFG" "$SB/work/pre-fb3.json")"
ok_eq "hot-swap(ado-fail): last-apply mode/reason/fallback" "restart hot-swap-failed 1" "$(la_get '@.mode') $(la_get '@.reason') $(la_get '@.fallback')"
# the rollback restart reloaded the restored config: running set matches again
api_sync
is "hot-swap(ado-fail): running set equals the restored config" "$(api_same_as_cfg && echo 1 || echo 0)"

echo "== hot-swap: fallback with an UNUSABLE snapshot still restarts + verifies"
# the snapshot cp fails (disk full): $COMMIT_BAK is missing when the live apply
# fails. The fallback must not skip the restart - verify_or_rollback runs with
# a missing backup and only demands xray come back up (on the candidate).
reset_cfg
api_sync
cp "$CFG" "$SB/work/pre-nosnap.json"
cp "$FIX/hs-staged.json" "$SB/state/staged.json"
r0=$(restarts)
REALCP=$(command -v cp)
cat > "$SB/bin/cp" <<EOF
#!/bin/sh
# cp shim: only the SNAPSHOT copy (cp -pL <cfg> <cfg>.bak.*) fails; every
# other copy goes to the real cp.
[ "\$1" = "-pL" ] && case "\$3" in *.bak.*) exit 1 ;; esac
exec "$REALCP" "\$@"
EOF
chmod 0755 "$SB/bin/cp"
touch "$STUB_API_FAIL"
STUB_UCI_HOTSWAP=1; export STUB_UCI_HOTSWAP
out=$(runsub apply 2>/dev/null); rc=$?
unset STUB_UCI_HOTSWAP
rm -f "$STUB_API_FAIL" "$SB/bin/cp"
ok_eq "hot-swap(no-snapshot): stdout" "hot-swap failed - rolled back to the previous config and restarted xray" "$out"
ok_eq "hot-swap(no-snapshot): rc" 1 "$rc"
ok_eq "hot-swap(no-snapshot): restart NOT skipped with the snapshot missing" "$((r0 + 1))" "$(restarts)"
is "hot-swap(no-snapshot): nothing to restore - the validated candidate stays installed" "$(differs "$CFG" "$SB/work/pre-nosnap.json")"
is "hot-swap(no-snapshot): no snapshot file left behind" "$([ -z "$(ls "$CFG".bak.* 2>/dev/null)" ] && echo 1 || echo 0)"
ok_eq "hot-swap(no-snapshot): status" "rolled-back" "$(cat "$SB/state/status" 2>/dev/null)"
ok_eq "hot-swap(no-snapshot): last-apply mode/reason/fallback" "restart hot-swap-failed 1" "$(la_get '@.mode') $(la_get '@.reason') $(la_get '@.fallback')"
api_sync

echo "== hot-swap: managed tag the shell cannot transport -> restart, reason tag-charset"
# staged proxy-de/vps is a legal xray tag and (legacy mode) managed, but the
# shell moves tags through unquoted lists and a hand-built rmo JSON - the plan
# must refuse the LIVE path before anything runs (never mid-flight).
reset_cfg
api_sync
cp "$FIX/hs-staged-badtag.json" "$SB/state/staged.json"
r0=$(restarts)
STUB_UCI_HOTSWAP=1; export STUB_UCI_HOTSWAP
out=$(runsub apply 2>/dev/null); rc=$?
unset STUB_UCI_HOTSWAP
ok_eq "hot-swap(tag-charset): stdout ok (restart path)" "ok" "$out"
ok_eq "hot-swap(tag-charset): rc" 0 "$rc"
ok_eq "hot-swap(tag-charset): restart invoked once" "$((r0 + 1))" "$(restarts)"
ok_eq "hot-swap(tag-charset): last-apply mode/reason" "restart tag-charset" "$(la_get '@.mode') $(la_get '@.reason')"
api_sync

echo "== hot-swap off (UCI hot_swap=0): every apply restarts, pre-F14 behavior"
reset_cfg
api_sync
cp "$FIX/hs-staged.json" "$SB/state/staged.json"
r0=$(restarts)
out=$(runsub apply 2>/dev/null); rc=$?
ok_eq "hot-swap(off): stdout" "ok" "$out"
ok_eq "hot-swap(off): rc" 0 "$rc"
ok_eq "hot-swap(off): restart invoked once" "$((r0 + 1))" "$(restarts)"
ok_eq "hot-swap(off): last-apply mode/reason" "restart " "$(la_get '@.mode') $(la_get '@.reason')"

echo "== mutation lock: a held flock blocks a second writer (NOWAIT fails at once)"
if [ "$FLOCK_STUB" = 1 ]; then
	echo "NOTE   flock(1) is a no-op stub here - lock cases skipped"
else
	reset_cfg
	cp "$FIX/staged-clean.json" "$SB/work/save-in.json"
	cp "$CFG" "$SB/work/pre-lock.json"
	# hold the sandbox lock exactly the way a real holder does: an exclusive
	# flock on an open descriptor of the lock file, kept alive by a subshell
	( exec 3>>"$SB/lock/xray-monitor"; flock -n 3 || exit 1; sleep 6 ) &
	holder=$!
	sleep 1
	t0=$(date +%s)
	out=$(runsub_nw config-save "$SB/work/save-in.json" 2>/dev/null); rc=$?
	t1=$(date +%s)
	ok_eq "lock(nowait): stdout" "another xray-monitor operation is running, try again in a moment" "$out"
	ok_eq "lock(nowait): rc" 1 "$rc"
	fast=0; [ $((t1 - t0)) -lt 4 ] && fast=1
	is "lock(nowait): failed fast, not after the ~55 s poll" "$fast"
	is "lock(nowait): live config untouched" "$(same "$CFG" "$SB/work/pre-lock.json")"
	# the same holder, now without NOWAIT: the writer waits inside the bound
	# and succeeds as soon as the holder lets go
	t0=$(date +%s)
	out=$(runsub config-save "$SB/work/save-in.json" 2>/dev/null); rc=$?
	t1=$(date +%s)
	ok_eq "lock(wait): stdout" "saved and restarted xray" "$out"
	ok_eq "lock(wait): rc" 0 "$rc"
	bounded=0; [ $((t1 - t0)) -le 30 ] && bounded=1
	is "lock(wait): succeeded within the bounded wait" "$bounded"
	echo "NOTE   lock(wait): waited $((t1 - t0)) s for the holder"
	wait "$holder"
	# the waiter released the lock on exit: a NOWAIT writer runs at once now
	t0=$(date +%s)
	out=$(runsub_nw config-save "$SB/work/save-in.json" 2>/dev/null); rc=$?
	t1=$(date +%s)
	ok_eq "lock(free): stdout" "saved and restarted xray" "$out"
	ok_eq "lock(free): rc" 0 "$rc"
	fast=0; [ $((t1 - t0)) -lt 3 ] && fast=1
	is "lock(free): lock released by the previous writer" "$fast"
fi

echo "== e2e exit check (F13): verdicts through the real runner"
# Fixture: e2e-ok (full body at speed), e2e-stall (18 KB arrive, then the
# transfer times out - the DPI freeze signature), e2e-fail (connect refused),
# e2e-skip (in probe_disabled: must never be dialled) and a freedom "direct"
# outbound (not an exit: no port, no curl). e2e-ok's fetches sleep 3 s so the
# runner is observably "running" and its progress file can be polled mid-run.
rm -f "$CFG".bak.* "$CFG.new"
cp "$FIX/e2e-config.json" "$CFG"
printf '0\n204|0.342|0.351|0|0\n3\n'            > "$SB/curltab/e2e-ok.204"
printf '0\n200|0.610|3.980|1048576|262144\n3\n' > "$SB/curltab/e2e-ok.body"
printf '0\n204|0.905|0.918|0|0\n'               > "$SB/curltab/e2e-stall.204"
printf '28\n200|1.120|45.000|18432|409\n'       > "$SB/curltab/e2e-stall.body"
printf '7\n000|0.000|0.000|0|0\n'               > "$SB/curltab/e2e-fail.204"
printf '7\n000|0.000|0.000|0|0\n'               > "$SB/curltab/e2e-fail.body"
: > "$STUB_CURL_LOG"
E2EJ="$SB/tmp/xray-monitor/e2e.json"
E2ERUN="$SB/tmp/xray-monitor/e2e.run"
rm -f "$E2EJ" "$E2EJ.new" "$E2ERUN" "$STUB_TMPXRAY_STATE"

# field of one exit's line in the runner's summary output
e2efield() {  # <tag> <column>
	printf '%s\n' "$e2eout" | awk -v t="$1" -v c="$2" '$1 == t { print $c }'
}

runsub e2e > "$SB/work/e2e.out" 2>/dev/null &
erun=$!
# while it runs: the pid marker exists and the skipped verdict is already in
# e2e.json (skipped exits are recorded before any connection is attempted)
i=0; seen=0
while [ "$i" -lt 10 ]; do
	if [ -s "$E2ERUN" ]; then
		seen=1
		break
	fi
	sleep 1
	i=$((i + 1))
done
is "e2e: run marker (e2e.run) appears while running" "$seen"
if [ "$seen" = 1 ]; then
	is "e2e: skipped verdict visible before any check ran" \
		"$("$SB/share/xray-monitor/e2e.uc" summary "$E2EJ" 2>/dev/null | awk '$1 == "e2e-skip" && $2 == "skipped"' | grep -c .)"
	is "e2e: progress file is the contract shape (ts + results)" \
		"$(grep -Ec '^\{"ts":[0-9]+,"results":\{|^\{ "ts": [0-9]+, "results": \{' "$E2EJ" 2>/dev/null)"
fi
wait "$erun"; erc=$?
e2eout=$(cat "$SB/work/e2e.out")
ok_eq "e2e: rc" 0 "$erc"
ok_eq "e2e: ok exit (full body at speed)" "ok" "$(e2efield e2e-ok 2)"
ok_eq "e2e: ok exit TTFB (ms)" "342" "$(e2efield e2e-ok 3)"
ok_eq "e2e: ok exit body bytes" "1048576" "$(e2efield e2e-ok 5)"
ok_eq "e2e: ok exit speed (B/s)" "262144" "$(e2efield e2e-ok 7)"
ok_eq "e2e: stalled exit (bytes froze mid-body)" "stalled" "$(e2efield e2e-stall 2)"
ok_eq "e2e: stalled exit bytes received" "18432" "$(e2efield e2e-stall 5)"
ok_eq "e2e: failed exit (connect error)" "fail" "$(e2efield e2e-fail 2)"
ok_eq "e2e: probe-disabled exit" "skipped" "$(e2efield e2e-skip 2)"
ok_eq "e2e: summary counts" "# ok=1 stalled=1 fail=1 skipped=1" \
	"$(printf '%s\n' "$e2eout" | grep '^# ')"
# e2e.json is one line: count OCCURRENCES (grep -c would cap every status at 1)
e2ecount() {  # <status>
	awk -v s="\"status\": \"$1\"" '{ n += gsub(s, "") } END { print n + 0 }' "$E2EJ" 2>/dev/null
}
ok_eq "e2e: e2e.json matches the summary (contract B3)" "1:1:1:1" \
	"$(e2ecount stalled):$(e2ecount ok):$(e2ecount fail):$(e2ecount skipped)"
ok_eq "e2e: exactly the checked exits dialled (3 exits x 2 URLs)" 6 "$(lines "$STUB_CURL_LOG")"
ok_eq "e2e: every fetch used the subscription user agent" 6 \
	"$(grep -c 'ua=v2rayNG/1.8.0 ' "$STUB_CURL_LOG")"
is "e2e: probe-disabled exit never dialled" "$([ "$(grep -c 'tag=e2e-skip ' "$STUB_CURL_LOG")" = 0 ] && echo 1 || echo 0)"
is "e2e: non-exit outbound (direct) never dialled" "$([ "$(grep -c 'tag=direct ' "$STUB_CURL_LOG")" = 0 ] && echo 1 || echo 0)"
is "e2e: tmpxray instance stopped after the run" "$([ ! -e "$STUB_TMPXRAY_STATE" ] && echo 1 || echo 0)"
is "e2e: run marker removed after the run" "$([ ! -e "$E2ERUN" ] && echo 1 || echo 0)"
ok_eq "e2e: default 204 URL used (3 checked exits)" 3 \
	"$(grep -c 'url=https://cp.cloudflare.com/generate_204' "$STUB_CURL_LOG")"

echo "== e2e: bad tag argument + tmpxray start failure both fail closed"
out=$(runsub e2e no-such-tag 2>/dev/null); rc=$?
ok_eq "e2e(bad tag): rc" 1 "$rc"
ok_eq "e2e(bad tag): stdout" "no such exit: no-such-tag" "$out"
is "e2e(bad tag): no curl ran" "$([ "$(lines "$STUB_CURL_LOG")" = 6 ] && echo 1 || echo 0)"
if [ "$FLOCK_STUB" = 1 ]; then
	echo "NOTE   flock(1) is a no-op stub here - busy-tmpxray case skipped"
else
	: > "$STUB_CURL_LOG"
	# hold the tmpxray mini-lock: start fails after its bounded poll, every
	# checked exit gets a fail verdict, nothing is dialled, state is cleaned
	( exec 4>>"$SB/lock/xray-monitor-tmpxray"; flock -n 4 || exit 1; sleep 14 ) &
	tholder=$!
	sleep 1
	out=$(runsub e2e 2>/dev/null); rc=$?
	wait "$tholder"
	ok_eq "e2e(busy tmpxray): rc" 1 "$rc"
	ok_eq "e2e(busy tmpxray): every checked exit recorded as fail" 3 "$(e2ecount fail)"
	is "e2e(busy tmpxray): no connection attempted" "$([ "$(lines "$STUB_CURL_LOG")" = 0 ] && echo 1 || echo 0)"
	is "e2e(busy tmpxray): run marker removed" "$([ ! -e "$E2ERUN" ] && echo 1 || echo 0)"
fi

echo "== cron-sync: fetch line always, e2e line only when enabled"
runsub cron-sync >/dev/null 2>&1
ok_eq "cron: fetch line present" 1 "$(grep -c "$SB/sub fetch" "$SB/etc/crontabs/root" 2>/dev/null)"
ok_eq "cron: no e2e line while e2e_cron=0" 0 "$(grep -c "$SB/sub e2e" "$SB/etc/crontabs/root" 2>/dev/null)"
STUB_UCI_E2E_CRON=1 runsub cron-sync >/dev/null 2>&1
ok_eq "cron: e2e line when e2e_cron=1" 1 "$(grep -c "$SB/sub e2e" "$SB/etc/crontabs/root" 2>/dev/null)"
is "cron: e2e line uses the (default) e2e_schedule" \
	"$(grep -c '^30 4 \* \* \* '"$SB"'/sub e2e' "$SB/etc/crontabs/root" 2>/dev/null)"
# and off again: the line is removed, the fetch line survives
STUB_UCI_E2E_CRON= runsub cron-sync >/dev/null 2>&1
ok_eq "cron: e2e line removed again" 0 "$(grep -c "$SB/sub e2e" "$SB/etc/crontabs/root" 2>/dev/null)"
ok_eq "cron: fetch line still there" 1 "$(grep -c "$SB/sub fetch" "$SB/etc/crontabs/root" 2>/dev/null)"

echo "== rpcd contract (F17): config_get hash, config_save optimistic lock, config_diff_text"
# The rpcd backend is ash + jshn.sh + jsonfilter + the jshn binary for dumps;
# those exist on the box the scenario is meant for (the router). Where they
# don't (a dev container), skip the whole section rather than fake them - a
# stubbed jshn/jsonfilter would test the stub, not the backend.
RPCD_OK=1
command -v jsonfilter >/dev/null 2>&1 || RPCD_OK=0
command -v jshn >/dev/null 2>&1 || RPCD_OK=0
[ -r /usr/share/libubox/jshn.sh ] || RPCD_OK=0
if [ "$RPCD_OK" = 0 ]; then
	echo "NOTE   jsonfilter/jshn unavailable - rpcd contract cases skipped"
else
	# Sandboxed copy of the rpcd backend: same code, its xray / SHARE / SUB and
	# config default pointed at this sandbox ($SB/sub is already the rewritten
	# xray-sub), jshn.sh sourced from a sandbox copy, and the one other live
	# writable path it names (the self-update log) rewritten too.
	sed \
		-e "s|^XRAY=.*|XRAY=$SB/bin/xray|" \
		-e "s|^SHARE=.*|SHARE=$SB/share/xray-monitor|" \
		-e "s|^SUB=.*|SUB=$SB/sub|" \
		-e "s|^E2E_STATE=.*|E2E_STATE=$SB/tmp/xray-monitor|" \
		-e "s|^\. /usr/share/libubox/jshn\.sh|. $SB/work/jshn.sh|" \
		-e "s|/usr/share/xray-monitor/xray-sub|$SB/sub|g" \
		-e "s|/tmp/xraymon-update\.log|$SB/tmp/xraymon-update.log|" \
		-e "s|echo \"/etc/xray/config.json\"|echo \"$SB/etc/xray/config.json\"|" \
		"$REPO/files/usr/libexec/rpcd/xray-monitor" > "$SB/rpcd"
	cp /usr/share/libubox/jshn.sh "$SB/work/jshn.sh"
	for pat in "XRAY=$SB/bin/xray" "SHARE=$SB/share" "SUB=$SB/sub" "$SB/work/jshn.sh" "$SB/etc/xray/config.json"; do
		grep -q -- "$pat" "$SB/rpcd" || { echo "scenario setup failed, rpcd rewrite missed: $pat"; exit 1; }
	done
	# safety net, same masking as for the sub copy: with the sandbox references
	# masked, no live writable path may remain reachable in the rpcd copy
	sed -e "s|$SB|<SB>|g" -e 's|<SB>/etc||g' -e 's|<SB>/tmp||g' "$SB/rpcd" > "$SB/work/rpcd-check.txt"
	if grep -q 'echo "/etc/xray' "$SB/work/rpcd-check.txt" \
		|| grep -Eq '/etc/|/usr/|/var/' "$SB/work/rpcd-check.txt" \
		|| grep -q '/tmp/' "$SB/work/rpcd-check.txt"; then
		echo "scenario setup failed: a live writable path is still reachable in the rpcd copy"; exit 1
	fi

	rpccall() {  # <method> [stdin-file] -> the backend's stdout
		PATH="$SB/bin:$PATH" sh "$SB/rpcd" call "$1" < "${2:-/dev/null}"
	}
	jget() { printf '%s' "$1" | jsonfilter -e "$2" 2>/dev/null; }
	# A config_save / config_diff_text request: the config text JSON-encoded
	# (the way the browser sends it), optionally with expected_hash.
	rpcinput() {  # <out-file> <config-file> [expected_hash]
		ucode -e 'import { readfile, writefile } from "fs";
			let o = { config: readfile(ARGV[0]) };
			if (length(ARGV[1])) o.expected_hash = ARGV[1];
			writefile(ARGV[2], sprintf("%J\n", o));' "$2" "${3:-}" "$1"
	}
	# what the pipeline itself would install for a request: the config text as
	# the backend decodes it out of the request JSON
	rpcconfig() {  # <request-file> <out-file>
		jsonfilter -i "$1" -e '@.config' > "$2"
	}

	# --- list / ACL: every declared method must be granted, new params present
	list_out=$(PATH="$SB/bin:$PATH" sh "$SB/rpcd" list)
	is "rpcd list: config_diff_text declared" "$(printf '%s' "$list_out" | grep -q '"config_diff_text"' && echo 1 || echo 0)"
	is "rpcd list: config_save declares expected_hash" "$(printf '%s' "$list_out" | grep -q '"expected_hash"' && echo 1 || echo 0)"
	printf '%s' "$list_out" > "$SB/work/list.json"
	missing=$(ucode -e 'import { readfile } from "fs";
		let acl = readfile(ARGV[0]), meth = keys(json(readfile(ARGV[1]))), miss = [];
		for (let i = 0; i < length(meth); i++)
			if (index(acl, "\"" + meth[i] + "\"") < 0) push(miss, meth[i]);
		print(join(" ", miss));' \
		"$REPO/files/usr/share/rpcd/acl.d/luci-app-xray-monitor.json" "$SB/work/list.json")
	ok_eq "rpcd list: every declared method is granted by the ACL" "" "$missing"

	# --- config_get: hash is the md5 of the file bytes, text round-trips
	reset_cfg
	out=$(rpccall config_get)
	ok_eq "rpcd config_get: hash = md5 of the config bytes" \
		"$(md5sum "$CFG" | awk '{ print $1 }')" "$(jget "$out" '@.hash')"
	ok_eq "rpcd config_get: path" "$CFG" "$(jget "$out" '@.path')"
	# the backend hands the text to jshn through $(cat ...), which drops the
	# file's trailing newline(s) - the editor sees exactly that string, so the
	# round-trip expectation must be built from the same $(cat) form
	printf '%s' "$(cat "$CFG")" > "$SB/work/cfg-as-loaded.json"
	rpcinput "$SB/work/get-in.json" "$SB/work/cfg-as-loaded.json"
	rpcconfig "$SB/work/get-in.json" "$SB/work/get-want.json"
	printf '%s' "$out" > "$SB/work/get-out.json"
	rpcconfig "$SB/work/get-out.json" "$SB/work/get-got.json"
	is "rpcd config_get: config text byte-exact through the JSON round trip" "$(same "$SB/work/get-want.json" "$SB/work/get-got.json")"

	# --- config_diff_text: editor text vs the LIVE config (added = saving adds)
	rpcinput "$SB/work/dt-same.json" "$CFG"
	rpccall config_diff_text "$SB/work/dt-same.json" > "$SB/work/dt-out.json"
	"$SB/share/xray-monitor/jsondiff-cli.uc" "$CFG" "$CFG" > "$SB/work/dt-want.json"
	is "rpcd config_diff_text: identical text -> empty diff (and it parses)" "$(same "$SB/work/dt-want.json" "$SB/work/dt-out.json")"
	ucode -e 'import { readfile, writefile } from "fs";
		let c = json(readfile(ARGV[0]));
		c.f17_marker = "added by the editor";
		writefile(ARGV[1], sprintf("%.2J\n", c));' "$CFG" "$SB/work/edited.json"
	rpcinput "$SB/work/dt-edit.json" "$SB/work/edited.json"
	rpccall config_diff_text "$SB/work/dt-edit.json" > "$SB/work/dt-out2.json"
	"$SB/share/xray-monitor/jsondiff-cli.uc" "$CFG" "$SB/work/edited.json" > "$SB/work/dt-want2.json"
	is "rpcd config_diff_text: edited text -> the same paths jsondiff reports" "$(same "$SB/work/dt-want2.json" "$SB/work/dt-out2.json")"
	ok_eq "rpcd config_diff_text: the edit shows up under added" "f17_marker" \
		"$(jsonfilter -i "$SB/work/dt-out2.json" -e '@.added[0]' 2>/dev/null)"
	# a comment-only change is legal in these configs and must not read as one
	ucode -e 'import { readfile, writefile } from "fs";
		writefile(ARGV[1], readfile(ARGV[0]) + "\n// === local ===\n");' "$CFG" "$SB/work/commented.json"
	rpcinput "$SB/work/dt-cmt.json" "$SB/work/commented.json"
	out=$(rpccall config_diff_text "$SB/work/dt-cmt.json")
	is "rpcd config_diff_text: comment-only change -> no semantic diff" "$(printf '%s' "$out" | grep -q '"added": \[ \], "removed": \[ \], "changed": \[ \]' && echo 1 || echo 0)"
	# text that does not parse is named, not a generic diff failure
	cat > "$SB/work/dt-bad.json" <<'EOF'
{"config":"{ \"outbounds\": [ "}
EOF
	out=$(rpccall config_diff_text "$SB/work/dt-bad.json")
	is "rpcd config_diff_text: invalid JSON reported as such" "$(printf '%s' "$out" | grep -q '"invalid JSON"' && echo 1 || echo 0)"
	is "rpcd config_diff_text: invalid JSON -> empty diff arrays" "$(printf '%s' "$out" | grep -q '"added":\[\]' && echo 1 || echo 0)"

	# --- config_save: the right hash saves through the whole pipeline
	reset_cfg
	r0=$(restarts); h0=$(hookruns)
	rpcinput "$SB/work/cs-ok.json" "$FIX/staged-clean.json" "$(md5sum "$CFG" | awk '{ print $1 }')"
	out=$(rpccall config_save "$SB/work/cs-ok.json")
	ok_eq "rpcd config_save(right hash): ok" "true" "$(jget "$out" '@.ok')"
	ok_eq "rpcd config_save(right hash): no conflict field" "" "$(jget "$out" '@.conflict')"
	rpcconfig "$SB/work/cs-ok.json" "$SB/work/cs-want.json"
	is "rpcd config_save(right hash): the uploaded text is what got installed" "$(same "$CFG" "$SB/work/cs-want.json")"
	is "rpcd config_save(right hash): manual backup created" "$([ -n "$(manual_bak)" ] && echo 1 || echo 0)"
	ok_eq "rpcd config_save(right hash): restart issued" "$((r0 + 1))" "$(restarts)"
	ok_eq "rpcd config_save(right hash): hooks ran" "$((h0 + 1))" "$(hookruns)"

	# --- config_save: a stale hash is refused and touches NOTHING
	reset_cfg
	rpcinput "$SB/work/cs-stale.json" "$FIX/staged-clean.json" "$(md5sum "$CFG" | awk '{ print $1 }')"
	cp "$FIX/staged-clean.json" "$CFG"      # meanwhile, someone else saved
	r0=$(restarts); h0=$(hookruns); b0=$(baks)
	out=$(rpccall config_save "$SB/work/cs-stale.json")
	ok_eq "rpcd config_save(stale hash): ok=false" "false" "$(jget "$out" '@.ok')"
	ok_eq "rpcd config_save(stale hash): conflict=true" "true" "$(jget "$out" '@.conflict')"
	is "rpcd config_save(stale hash): msg says reload and re-apply" "$(printf '%s' "$out" | grep -q 'changed on the router' && echo 1 || echo 0)"
	is "rpcd config_save(stale hash): live config untouched" "$(same "$CFG" "$FIX/staged-clean.json")"
	is "rpcd config_save(stale hash): editor content not staged anywhere" "$([ ! -e "$CFG.new" ] && echo 1 || echo 0)"
	ok_eq "rpcd config_save(stale hash): no backup" "$b0" "$(baks)"
	ok_eq "rpcd config_save(stale hash): no restart" "$r0" "$(restarts)"
	ok_eq "rpcd config_save(stale hash): no hooks" "$h0" "$(hookruns)"

	# --- config_save: no hash at all / an explicitly empty one = old behavior
	reset_cfg
	rpcinput "$SB/work/cs-nohash.json" "$FIX/staged-clean.json"
	out=$(rpccall config_save "$SB/work/cs-nohash.json")
	ok_eq "rpcd config_save(no hash): ok (backward compat)" "true" "$(jget "$out" '@.ok')"
	reset_cfg
	ucode -e 'import { readfile, writefile } from "fs";
		writefile(ARGV[1], sprintf("%J\n", { config: readfile(ARGV[0]), expected_hash: "" }));' \
		"$FIX/staged-clean.json" "$SB/work/cs-emptyhash.json"
	out=$(rpccall config_save "$SB/work/cs-emptyhash.json")
	ok_eq "rpcd config_save(empty hash): ok (what the UI sends when it has none)" "true" "$(jget "$out" '@.ok')"

	# --- hash path handling: symlinked config, and no config at all
	rm -f "$CFG" "$CFG".bak.* "$CFG.new"
	cp "$FIX/config.json" "$SB/etc/xray/config.real.json"
	ln -s "$SB/etc/xray/config.real.json" "$CFG"
	out=$(rpccall config_get)
	ok_eq "rpcd config_get(symlink): hash = md5 of the TARGET's bytes" \
		"$(md5sum "$SB/etc/xray/config.real.json" | awk '{ print $1 }')" "$(jget "$out" '@.hash')"
	rm -f "$CFG" "$SB/etc/xray/config.real.json"
	out=$(rpccall config_get)
	ok_eq "rpcd config_get(no config file): hash empty" "" "$(jget "$out" '@.hash')"
	ok_eq "rpcd config_get(no config file): text empty, not an error" "" "$(jget "$out" '@.config')"
	reset_cfg
fi
echo "== fetch/self-update via xray (F18): exit selection order + honest proxy failures"
# curl / ubus / tmpxray are stubbed (see setup); uci answers, the e2e.json
# fixture state and the failure flags are (re)seeded per case.
via_reset() {  # <fetch_via> [fetch_via_exit] — uci, flags, logs, fetch state
	# these sections run against the stubbed tmpxray boundary (setup above);
	# the flag stays set until the section cleanup below unsets it again
	export STUB_TMPXRAY_OVERRIDE=1
	rm -f "$STUB_TMPXRAY_FAIL" "$STUB_CURL_FAIL_ALL" "$STUB_CURL_DIRECT_DOWN"
	rm -f "$SB/tmp/xray-monitor/e2e.json" "$SB/state/fetch_path" "$SB/state/update_path"
	rm -f "$SB/state/usage-proxy.json" "$SB/state/title-proxy.txt" "$SB/state/tagmap-proxy.json"
	rm -f "$SB/tmp/luci-app-xray-monitor.ipk"
	# restore the correct checksum sidecar (the mismatch case overwrites it)
	printf '%s  luci-app-xray-monitor.ipk\n' \
		"$(sha256sum "$STUB_CURL_IPK" 2>/dev/null | awk '{ print $1 }')" > "$STUB_CURL_SHA256"
	: > "$STUB_CURL_LOG"; : > "$STUB_TMPXRAY_LOG"; : > "$STUB_UBUS_LOG"
	printf '%s\n' \
		"xray-monitor.sub=xray-monitor" \
		"xray-monitor.sub.backup_keep='3'" \
		"xray-monitor.sub.user_agent='v2rayNG/1.8.0'" \
		"xray-monitor.sub.fetch_via='$1'" \
		"xray-monitor.sub.fetch_via_exit='${2:-auto}'" \
		"xray-monitor.@subscription[0]=subscription" \
		"xray-monitor.@subscription[0].prefix='proxy'" \
		"xray-monitor.@subscription[0].url='https://panel.example/sub/tok'" \
		"xray-monitor.@subscription[0].enabled='1'" > "$STUB_UCI"
}
via_seed_e2e() {  # fresh e2e.json: proxy-de best ok exit, proxy-ru stalled decoy
	printf '{"ts":%s,"results":{"proxy-fi":{"status":"ok","speed_bps":102400},"proxy-de":{"status":"ok","speed_bps":873813},"proxy-ru":{"status":"stalled","speed_bps":999999}}}' \
		"$(date +%s)" > "$SB/tmp/xray-monitor/e2e.json"
}
via_seed_e2e_stale() {  # same winner, but measured 2 h ago
	printf '{"ts":%s,"results":{"proxy-de":{"status":"ok","speed_bps":873813}}}' \
		"$(( $(date +%s) - 7200 ))" > "$SB/tmp/xray-monitor/e2e.json"
}
has_line()  { grep -q -- "$2" "$1"; }
nth_socks() { sed -n "$2p" "$STUB_CURL_LOG" | grep -q "curl\[socks=$3\]"; }

# 1) proxy mode + fresh e2e.json: best ok exit wins, the rpcd fallback is not
#    consulted, and the proxied curl keeps UA / --max-time / -D header capture
via_reset proxy
via_seed_e2e
out=$(runsub fetch 2>/dev/null); rc=$?
ok_eq "via(proxy,e2e): rc" 0 "$rc"
ok_eq "via(proxy,e2e): status" "ok" "$(cat "$SB/state/status" 2>/dev/null)"
ok_eq "via(proxy,e2e): tmpxray started for the best ok exit, then stopped" \
	"$(printf 'start proxy-de\nstop')" "$(cat "$STUB_TMPXRAY_LOG")"
ok_eq "via(proxy,e2e): one fetch, through the socks port" 1 "$(lines "$STUB_CURL_LOG")"
is "via(proxy,e2e): socks5-hostname with the tmpxray port" "$(has_line "$STUB_CURL_LOG" -- "--socks5-hostname 127.0.0.1:11080" && echo 1 || echo 0)"
is "via(proxy,e2e): same user agent as the direct path" "$(has_line "$STUB_CURL_LOG" -- "-A v2rayNG/1.8.0" && echo 1 || echo 0)"
is "via(proxy,e2e): same --max-time bound" "$(has_line "$STUB_CURL_LOG" -- "--max-time 25" && echo 1 || echo 0)"
is "via(proxy,e2e): response headers still captured (-D)" "$(has_line "$STUB_CURL_LOG" -- "-D " && echo 1 || echo 0)"
is "via(proxy,e2e): e2e answered, rpcd fallback NOT consulted" "$([ "$(lines "$STUB_UBUS_LOG")" = 0 ] && echo 1 || echo 0)"
ok_eq "via(proxy,e2e): fetch_path token" "via proxy-de" "$(cat "$SB/state/fetch_path" 2>/dev/null)"
is "via(proxy,e2e): subscription-userinfo captured through the proxy" "$([ -s "$SB/state/usage-proxy.json" ] && echo 1 || echo 0)"

# 2) stale e2e.json -> rpcd outbounds fallback: FIRST outbound with up=1
#    (config order), not a later one and not a down one
via_reset proxy
via_seed_e2e_stale
printf '%s\n' '{"outbounds":[{"tag":"proxy-fi","up":0},{"tag":"proxy-ch","up":0},{"tag":"proxy-de","up":1},{"tag":"proxy-ru","up":1}]}' > "$STUB_UBUS_OUT"
out=$(runsub fetch 2>/dev/null); rc=$?
ok_eq "via(proxy,stale e2e): rc" 0 "$rc"
ok_eq "via(proxy,stale e2e): status" "ok" "$(cat "$SB/state/status" 2>/dev/null)"
ok_eq "via(proxy,stale e2e): first up=1 outbound in config order chosen" \
	"$(printf 'start proxy-de\nstop')" "$(cat "$STUB_TMPXRAY_LOG")"
ok_eq "via(proxy,stale e2e): fallback consulted once" 1 "$(lines "$STUB_UBUS_LOG")"
ok_eq "via(proxy,stale e2e): fetch_path token" "via proxy-de" "$(cat "$SB/state/fetch_path" 2>/dev/null)"

# 3) proxy mode with NOTHING selectable: honest fetch-error, never a silent
#    direct fallback (no curl call at all)
via_reset proxy
printf '%s\n' '{"outbounds":[{"tag":"proxy-fi","up":0},{"tag":"proxy-de","up":0}]}' > "$STUB_UBUS_OUT"
out=$(runsub fetch 2>&1); rc=$?
ok_eq "via(no exit): rc" 1 "$rc"
ok_eq "via(no exit): honest status" "fetch-error" "$(cat "$SB/state/status" 2>/dev/null)"
is "via(no exit): no fetch over any transport" "$([ "$(lines "$STUB_CURL_LOG")" = 0 ] && echo 1 || echo 0)"
is "via(no exit): no tmpxray started" "$([ "$(lines "$STUB_TMPXRAY_LOG")" = 0 ] && echo 1 || echo 0)"
is "via(no exit): reason surfaced on stderr" "$(printf '%s' "$out" | grep -q 'no exit selectable' && echo 1 || echo 0)"
ok_eq "via(no exit): fetch_path cleared" "" "$(cat "$SB/state/fetch_path" 2>/dev/null)"

# 4) auto mode, direct down: the failed sub is retried through xray with the
#    same UA / timeout / header capture, and the token says so
via_reset auto
via_seed_e2e
touch "$STUB_CURL_DIRECT_DOWN"
out=$(runsub fetch 2>/dev/null); rc=$?
ok_eq "auto(direct down): rc" 0 "$rc"
ok_eq "auto(direct down): status" "ok" "$(cat "$SB/state/status" 2>/dev/null)"
ok_eq "auto(direct down): direct attempt, then proxied retry" 2 "$(lines "$STUB_CURL_LOG")"
is "auto(direct down): first attempt was direct" "$(nth_socks "$STUB_CURL_LOG" 1 0 && echo 1 || echo 0)"
is "auto(direct down): retry went through the socks port" "$(nth_socks "$STUB_CURL_LOG" 2 1 && echo 1 || echo 0)"
is "auto(direct down): proxied retry keeps the user agent" "$(sed -n 2p "$STUB_CURL_LOG" | grep -q -- "-A v2rayNG/1.8.0" && echo 1 || echo 0)"
ok_eq "auto(direct down): fetch_path token" "direct, retried via proxy-de" "$(cat "$SB/state/fetch_path" 2>/dev/null)"
is "auto(direct down): usage header captured on the retry" "$([ -s "$SB/state/usage-proxy.json" ] && echo 1 || echo 0)"

# 5) auto mode, direct fine: no exit is even selected, tmpxray never starts
via_reset auto
out=$(runsub fetch 2>/dev/null); rc=$?
ok_eq "auto(direct up): status" "ok" "$(cat "$SB/state/status" 2>/dev/null)"
ok_eq "auto(direct up): one direct fetch" 1 "$(lines "$STUB_CURL_LOG")"
is "auto(direct up): fetch was direct" "$(nth_socks "$STUB_CURL_LOG" 1 0 && echo 1 || echo 0)"
is "auto(direct up): tmpxray never started" "$([ "$(lines "$STUB_TMPXRAY_LOG")" = 0 ] && echo 1 || echo 0)"
is "auto(direct up): exit never selected (no ubus, no e2e consult)" "$([ "$(lines "$STUB_UBUS_LOG")" = 0 ] && echo 1 || echo 0)"
ok_eq "auto(direct up): fetch_path token" "direct" "$(cat "$SB/state/fetch_path" 2>/dev/null)"

# 6) proxy mode, tmpxray itself cannot start: honest failure, no direct leak
via_reset proxy proxy-fi
touch "$STUB_TMPXRAY_FAIL"
out=$(runsub fetch 2>&1); rc=$?
ok_eq "via(tmpxray fail): rc" 1 "$rc"
ok_eq "via(tmpxray fail): honest status" "fetch-error" "$(cat "$SB/state/status" 2>/dev/null)"
is "via(tmpxray fail): no fetch attempted" "$([ "$(lines "$STUB_CURL_LOG")" = 0 ] && echo 1 || echo 0)"
is "via(tmpxray fail): concrete tag skips selection (no ubus call)" "$([ "$(lines "$STUB_UBUS_LOG")" = 0 ] && echo 1 || echo 0)"
is "via(tmpxray fail): tmpxray failure surfaced" "$(printf '%s' "$out" | grep -q 'proxy path unavailable' && printf '%s' "$out" | grep -q 'tmpxray' && echo 1 || echo 0)"
ok_eq "via(tmpxray fail): fetch_path cleared" "" "$(cat "$SB/state/fetch_path" 2>/dev/null)"

# 7) self-update via proxy: BOTH downloads proxied, SHA256 gate intact, opkg
#    stays local, and the instance is stopped BEFORE opkg runs
via_reset proxy
echo "xray-monitor.sub.fetch_via_update='proxy'" >> "$STUB_UCI"
via_seed_e2e
o0=$(lines "$STUB_OPKG_LOG")
out=$(runsub self-update 2>/dev/null); rc=$?
ok_eq "upd(via): stdout" "updated" "$out"
ok_eq "upd(via): rc" 0 "$rc"
ok_eq "upd(via): opkg ran once, locally" "$((o0 + 1))" "$(lines "$STUB_OPKG_LOG")"
is "upd(via): opkg install of the verified file" "$(grep -q -- "install --force-reinstall" "$STUB_OPKG_LOG" && echo 1 || echo 0)"
ok_eq "upd(via): .ipk and .sha256 both fetched through the proxy" 2 "$(grep -c 'socks=1' "$STUB_CURL_LOG")"
is "upd(via): no direct download leaked" "$(grep -q 'socks=0' "$STUB_CURL_LOG" && echo 0 || echo 1)"
ok_eq "upd(via): update_path token" "via proxy-de" "$(cat "$SB/state/update_path" 2>/dev/null)"
stopline=$(grep -n '^stop$' "$STUB_TMPXRAY_LOG" | tail -n1 | cut -d: -f1)
opkgline=$(grep -n '^opkg-mark$' "$STUB_TMPXRAY_LOG" | tail -n1 | cut -d: -f1)
is "upd(via): proxy instance stopped BEFORE opkg install" \
	"$([ -n "$stopline" ] && [ -n "$opkgline" ] && [ "$opkgline" -gt "$stopline" ] && echo 1 || echo 0)"
is "upd(via): downloaded file cleaned up" "$([ ! -e "$SB/tmp/luci-app-xray-monitor.ipk" ] && echo 1 || echo 0)"

# 8) self-update via proxy, checksum mismatch: refuse, never hand it to opkg
via_reset proxy
echo "xray-monitor.sub.fetch_via_update='proxy'" >> "$STUB_UCI"
via_seed_e2e
printf '%s  luci-app-xray-monitor.ipk\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$STUB_CURL_SHA256"
o0=$(lines "$STUB_OPKG_LOG")
out=$(runsub self-update 2>/dev/null); rc=$?
ok_eq "upd(sha bad): rc" 1 "$rc"
is "upd(sha bad): refuses with the mismatch reason" "$(printf '%s' "$out" | grep -q '^SHA256 mismatch' && echo 1 || echo 0)"
ok_eq "upd(sha bad): opkg never called" "$o0" "$(lines "$STUB_OPKG_LOG")"
is "upd(sha bad): refused download removed" "$([ ! -e "$SB/tmp/luci-app-xray-monitor.ipk" ] && echo 1 || echo 0)"
is "upd(sha bad): proxy instance still stopped (trap)" "$(grep -q '^stop$' "$STUB_TMPXRAY_LOG" && echo 1 || echo 0)"

# 9) self-update default (no fetch_via_update): exactly today's direct flow
via_reset direct
o0=$(lines "$STUB_OPKG_LOG")
out=$(runsub self-update 2>/dev/null); rc=$?
ok_eq "upd(default): stdout" "updated" "$out"
ok_eq "upd(default): rc" 0 "$rc"
ok_eq "upd(default): .ipk + .sha256 fetched directly" 2 "$(grep -c 'socks=0' "$STUB_CURL_LOG")"
is "upd(default): no proxy instance started" "$(grep -q '^start ' "$STUB_TMPXRAY_LOG" && echo 0 || echo 1)"
ok_eq "upd(default): update_path token" "direct" "$(cat "$SB/state/update_path" 2>/dev/null)"

# 10) self-update auto with direct down: retried through xray, token says so
via_reset direct
echo "xray-monitor.sub.fetch_via_update='auto'" >> "$STUB_UCI"
via_seed_e2e
touch "$STUB_CURL_DIRECT_DOWN"
out=$(runsub self-update 2>/dev/null); rc=$?
ok_eq "upd(auto retry): stdout" "updated" "$out"
ok_eq "upd(auto retry): rc" 0 "$rc"
ok_eq "upd(auto retry): direct attempts first, then proxied" "2 2" "$(grep -c 'socks=0' "$STUB_CURL_LOG") $(grep -c 'socks=1' "$STUB_CURL_LOG")"
ok_eq "upd(auto retry): update_path token" "direct, retried via proxy-de" "$(cat "$SB/state/update_path" 2>/dev/null)"
is "upd(auto retry): proxy instance stopped after the downloads" "$(grep -q '^stop$' "$STUB_TMPXRAY_LOG" && echo 1 || echo 0)"

# restore the default uci answers so any later section sees the base state,
# and drop the tmpxray-boundary override flag again
printf '%s\n' "xray-monitor.sub=xray-monitor" "xray-monitor.sub.backup_keep='3'" > "$STUB_UCI"
rm -f "$STUB_TMPXRAY_FAIL" "$STUB_CURL_FAIL_ALL" "$STUB_CURL_DIRECT_DOWN"
unset STUB_TMPXRAY_OVERRIDE

echo
if [ "$fails" -eq 0 ]; then
	if [ "$KEEP" = 1 ]; then echo "pipeline scenario passed (sandbox kept: $SB)"
	else echo "pipeline scenario passed"; fi
	exit 0
fi
echo "$fails assertion(s) failed"
exit 1
