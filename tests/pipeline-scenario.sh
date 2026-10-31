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
# no-restart (install only), a prune failure that must not fail the write, and
# the mutation lock itself: a held flock fails a NOWAIT writer at once and a
# waiting writer succeeds after the holder lets go (only where flock(1) is
# real - a stubbed flock serializes nothing).
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
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$SB"; return 0; }
trap cleanup EXIT

mkdir -p "$SB/bin" "$SB/etc/init.d" "$SB/etc/xray" "$SB/state" "$SB/lock" "$SB/log" \
	"$SB/work" "$SB/tmp" "$SB/share" "$SB/flags" "$SB/tmp/xray-monitor"
cp -a "$SHARESRC" "$SB/share/xray-monitor"

# The sandboxed copy: same code, every writable path pointed into the sandbox
# (write pipeline, both locks, tmpxray state, cron-sync, self-update's
# download). post_restart_hooks gets a logging body so the scenario can
# observe it; everything else is byte-identical to the installed script.
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
	-e "s|/tmp/luci-app-xray-monitor\.ipk|$SB/tmp/luci-app-xray-monitor.ipk|g" \
	-e 's|post_restart_hooks() { return 0; }|post_restart_hooks() { echo hook >> "${STUB_HOOK_LOG:-/dev/null}"; return 0; }|' \
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
cat > "$SB/work/tmpxray-override.sh" <<'EOF'

# --- scenario override: stub the tmpxray (B2) start/stop boundary -----------
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
# xray stub: `-test` validates by marker, `api statsquery` pretends the stats
# API answers. Every `-test` (and its verdict) is logged to $STUB_LOG.
LOG=${STUB_LOG:-/dev/null}
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
	api) exit 0 ;;
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
# uci stub: keeps the sandbox off the live UCI by serving `show`/`get` from a
# uci-show-format file ($STUB_UCI) the scenario rewrites per case - the F18
# fetch-via sections configure subscriptions and fetch_via* options that way.
# The default file answers only backup_keep=3 (prune budget pinned, sub list
# empty = legacy "all proxy outbounds are managed" mode), matching the original
# hardcoded stub. Anything else (add/set/commit/...) fails like before.
while [ $# -gt 0 ]; do
	case "$1" in
		-q) ;;
		show)
			[ -n "${STUB_UCI:-}" ] && cat "$STUB_UCI" 2>/dev/null
			exit 0 ;;
		get)
			[ -n "${STUB_UCI:-}" ] && [ -n "$2" ] || exit 1
			while IFS= read -r line; do
				# fixed-prefix match via case (no regex: section ids carry
				# [ ] and dots that must not be interpreted)
				case "$line" in "$2="*)
					v=${line#*=}; v=${v#\'}; v=${v%\'}
					echo "$v"; exit 0 ;;
				esac
			done < "$STUB_UCI"
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
# curl stub for the F18 fetch-via cases. Logs the full argv (with a socks=
# marker so direct vs proxied calls are distinguishable), then answers from
# per-URL canned files so a whole self-update can run against it:
#   *.sha256  -> $STUB_CURL_SHA256     *.ipk -> $STUB_CURL_IPK
#   *Packages -> $STUB_CURL_PACKAGES   else  -> $STUB_CURL_BODY (fetch body)
# $STUB_CURL_HDR is copied into the -D header-dump file, keeping the
# subscription-userinfo capture in play on the proxy path too. Flags:
#   $STUB_CURL_FAIL_ALL     every call fails
#   $STUB_CURL_DIRECT_DOWN  calls WITHOUT --socks5-hostname fail (direct is
#                           down, the proxy works - the auto-mode retry case)
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
cat > "$SB/etc/init.d/xray" <<'EOF'
#!/bin/sh
# init script stub: records what it was asked to do instead of restarting xray
echo "$*" >> "${STUB_INITD_LOG:-/dev/null}"
exit 0
EOF
cp "$SB/etc/init.d/xray" "$SB/etc/init.d/cron"
chmod 0755 "$SB/bin/xray" "$SB/bin/pgrep" "$SB/bin/uci" "$SB/bin/opkg" \
	"$SB/bin/ubus" "$SB/bin/curl" \
	"$SB/etc/init.d/xray" "$SB/etc/init.d/cron" "$SB/sub"
touch "$SB/lock/xray-monitor"

export TMPDIR="$SB/tmp"
export STUB_LOG="$SB/log/xray-test.log"
export STUB_HOOK_LOG="$SB/log/hooks.log"
export STUB_INITD_LOG="$SB/log/initd.log"
export STUB_PGREP_DOWN="$SB/flags/xray-down"
export STUB_OPKG_LOG="$SB/log/opkg.log"
# F18 fetch-via plumbing: uci answers come from a file, ubus serves the rpcd
# outbounds surface, curl/tmpxray log their calls, and the failure flags let
# individual cases take the proxy down.
export STUB_UCI="$SB/work/uci-show.txt"
export STUB_UBUS_LOG="$SB/log/ubus.log"
export STUB_UBUS_OUT="$SB/work/ubus-outbounds.json"
export STUB_CURL_LOG="$SB/log/curl.log"
export STUB_CURL_BODY="$FIX/sub1.json"
export STUB_CURL_HDR="$SB/work/curl-hdrs.txt"
export STUB_CURL_IPK="$SB/work/fake-update.ipk"
export STUB_CURL_SHA256="$SB/work/fake-update.sha256"
export STUB_CURL_PACKAGES="$SB/work/fake-Packages"
export STUB_TMPXRAY_LOG="$SB/log/tmpxray.log"
export STUB_TMPXRAY_FAIL="$SB/flags/tmpxray-fail"
export STUB_CURL_FAIL_ALL="$SB/flags/curl-fail-all"
export STUB_CURL_DIRECT_DOWN="$SB/flags/curl-direct-down"
: > "$STUB_LOG"; : > "$STUB_HOOK_LOG"; : > "$STUB_INITD_LOG"; : > "$STUB_OPKG_LOG"
: > "$STUB_UBUS_LOG"; : > "$STUB_CURL_LOG"; : > "$STUB_TMPXRAY_LOG"
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

echo "== fetch/self-update via xray (F18): exit selection order + honest proxy failures"
# curl / ubus / tmpxray are stubbed (see setup); uci answers, the e2e.json
# fixture state and the failure flags are (re)seeded per case.
via_reset() {  # <fetch_via> [fetch_via_exit] — uci, flags, logs, fetch state
	rm -f "$STUB_TMPXRAY_FAIL" "$STUB_CURL_FAIL_ALL" "$STUB_CURL_DIRECT_DOWN"
	rm -f "$SB/tmp/xray-monitor/e2e.json" "$SB/state/fetch_path" "$SB/state/update_path"
	rm -f "$SB/state/usage-proxy.json" "$SB/state/title-proxy.txt" "$SB/state/tagmap-proxy.json"
	rm -f "$SB/tmp/luci-app-xray-monitor.ipk"
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

# restore the default uci answers so any later section sees the base state
printf '%s\n' "xray-monitor.sub=xray-monitor" "xray-monitor.sub.backup_keep='3'" > "$STUB_UCI"
rm -f "$STUB_TMPXRAY_FAIL" "$STUB_CURL_FAIL_ALL" "$STUB_CURL_DIRECT_DOWN"

echo
if [ "$fails" -eq 0 ]; then
	if [ "$KEEP" = 1 ]; then echo "pipeline scenario passed (sandbox kept: $SB)"
	else echo "pipeline scenario passed"; fi
	exit 0
fi
echo "$fails assertion(s) failed"
exit 1
