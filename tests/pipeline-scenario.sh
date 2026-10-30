#!/bin/sh
# Sandbox scenario for the config write pipeline in xray-sub (F-prep:
# commit_config + post_restart_hooks + no-restart mode). Everything runs inside
# a throwaway sandbox: a copy of xray-sub with its paths rewritten, the real
# .uc transforms, and stubs for xray / pgrep / uci / /etc/init.d/xray that only
# log. The live router is never touched - no service restart, nothing outside
# the sandbox is written.
#   sh tests/pipeline-scenario.sh [sandbox-dir]     (needs ucode + ucode-mod-fs)
#   KEEP_SB=1 sh tests/pipeline-scenario.sh ...     keep the sandbox for review
# Covered, per write path (apply / routing-set / balancers-set / config-save /
# enable-api): backup name+kind, candidate validated then installed, restart
# invoked, post_restart_hooks fired, prune_backups run; plus the test-failed
# path, the verify-failed (rollback) path, and no-restart (install only).
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
	"$SB/work" "$SB/tmp" "$SB/share" "$SB/flags"
cp -a "$SHARESRC" "$SB/share/xray-monitor"

# The sandboxed copy: same code, every path pointed into the sandbox.
# post_restart_hooks gets a logging body so the scenario can observe it;
# everything else is byte-identical to the installed script.
sed \
	-e "s|^SHARE=.*|SHARE=$SB/share/xray-monitor|" \
	-e "s|^STATE=.*|STATE=$SB/state|" \
	-e "s|^XRAY=.*|XRAY=$SB/bin/xray|" \
	-e "s|^LOCK=.*|LOCK=$SB/lock/xray-monitor|" \
	-e "s|echo \"/etc/xray/config.json\"|echo \"$SB/etc/xray/config.json\"|" \
	-e "s|/etc/init\.d/xray|$SB/etc/init.d/xray|g" \
	-e 's|post_restart_hooks() { return 0; }|post_restart_hooks() { echo hook >> "${STUB_HOOK_LOG:-/dev/null}"; return 0; }|' \
	"$SHARESRC/xray-sub" > "$SB/sub"
for pat in "SHARE=$SB" "STATE=$SB" "XRAY=$SB" "LOCK=$SB" "$SB/etc/xray/config.json" "STUB_HOOK_LOG"; do
	grep -q -- "$pat" "$SB/sub" || { echo "scenario setup failed, rewrite missed: $pat"; exit 1; }
done
# safety net: the copy must not reach the live config or the real init script.
# ($SB itself contains "/etc/init.d/xray", so compare occurrence counts.)
n_all=$(grep -o '/etc/init\.d/xray' "$SB/sub" | wc -l | tr -d ' ')
n_sbx=$(grep -o "$SB/etc/init\.d/xray" "$SB/sub" | wc -l | tr -d ' ')
if grep -q 'echo "/etc/xray' "$SB/sub" || [ "$n_all" != "$n_sbx" ]; then
	echo "scenario setup failed: live /etc still reachable in the copy"; exit 1
fi

# OpenWrt's lock(1) is what actually serializes writers; elsewhere (dev boxes)
# fall back to a no-op so the scenario can still exercise the pipeline.
if ! command -v lock >/dev/null 2>&1; then
	printf '#!/bin/sh\n# no-op lock(1) stand-in (not on OpenWrt): no real serialization\nexit 0\n' > "$SB/bin/lock"
	echo "NOTE   lock(1) not found - using a no-op stub"
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
# uci stub: keeps the sandbox off the live UCI - every query comes back empty
# (sub_prefixes empty = legacy "all proxy outbounds are managed" mode)
exit 1
EOF
cat > "$SB/etc/init.d/xray" <<'EOF'
#!/bin/sh
# init script stub: records what it was asked to do instead of restarting xray
echo "$*" >> "${STUB_INITD_LOG:-/dev/null}"
exit 0
EOF
chmod 0755 "$SB/bin/xray" "$SB/bin/pgrep" "$SB/bin/uci" "$SB/etc/init.d/xray" "$SB/sub"
touch "$SB/lock/xray-monitor"

export TMPDIR="$SB/tmp"
export STUB_LOG="$SB/log/xray-test.log"
export STUB_HOOK_LOG="$SB/log/hooks.log"
export STUB_INITD_LOG="$SB/log/initd.log"
export STUB_PGREP_DOWN="$SB/flags/xray-down"
: > "$STUB_LOG"; : > "$STUB_HOOK_LOG"; : > "$STUB_INITD_LOG"

CFG="$SB/etc/xray/config.json"
fails=0

pass() { echo "PASS   $1"; }
fail() { echo "FAIL   $1"; fails=$((fails + 1)); }
ok_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: want [$2] got [$3]"; fi; }
is()    { if [ "$2" = 1 ]; then pass "$1"; else fail "$1"; fi; }
same()  { if cmp -s "$1" "$2"; then echo 1; else echo 0; fi; }
differs() { if cmp -s "$1" "$2"; then echo 0; else echo 1; fi; }

runsub()    { PATH="$SB/bin:$PATH" sh "$SB/sub" "$@"; }
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
	i=0
	while [ "$i" -lt "$1" ]; do
		i=$((i + 1))
		cp "$CFG" "$CFG.bak.seed$i"
		[ "$TOUCH_T" = 1 ] && touch -t 202001010000 "$CFG.bak.seed$i"
	done
}

echo "== apply: auto backup, candidate tested + installed, restart, hooks, prune"
reset_cfg
seed_baks 5
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
[ "$TOUCH_T" = 1 ] && ok_eq "apply: prune kept 3 backups" 3 "$(baks)"
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
ok_eq "test-failed: backup still taken (as before the refactor)" "$((b0 + 1))" "$(baks)"

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
stage_init
cp "$SB/work/nr-bad.json" "\$STAGE_DIR/config.json"
commit_config "" 0 "\$STAGE_DIR/config.json" no-restart
echo "rc=\$?"
EOF
cat "$SB/lib.sh" "$SB/work/nrbad-driver.sh" > "$SB/work/nrbad-run.sh"
nr2=$(PATH="$SB/bin:$PATH" sh "$SB/work/nrbad-run.sh" 2>/dev/null); nr2rc=$?
ok_eq "no-restart(bad candidate): commit_config rc=1" 1 "$(printf '%s\n' "$nr2" | sed -n 's/^rc=//p')"
ok_eq "no-restart(bad candidate): driver rc" 0 "$nr2rc"
is "no-restart(bad candidate): live config untouched" "$(same "$CFG" "$SB/work/nr-cand.json")"

echo "== no-restart + fallback: the documented F14 recipe (restore + restart + verify)"
reset_cfg
cat > "$SB/work/fb-driver.sh" <<EOF
stage_init
cp "$SB/work/nr-cand.json" "\$STAGE_DIR/config.json"
commit_config "" 1 "\$STAGE_DIR/config.json" no-restart || { echo "install_rc=\$?"; exit 1; }
# simulated hot-swap failure -> fall back to a full restart + verify
cp -a "\$COMMIT_BAK" "\$CFG"
"$SB/etc/init.d/xray" restart >/dev/null 2>&1
verify_or_rollback "\$COMMIT_BAK" 1
echo "fallback_rc=\$?"
EOF
cat "$SB/lib.sh" "$SB/work/fb-driver.sh" > "$SB/work/fb-run.sh"
fb=$(PATH="$SB/bin:$PATH" sh "$SB/work/fb-run.sh" 2>/dev/null); fbrc=$?
ok_eq "fallback: driver rc" 0 "$fbrc"
ok_eq "fallback: restore + restart + verify healthy" 0 "$(printf '%s\n' "$fb" | sed -n 's/^fallback_rc=//p')"
is "fallback: config back to the snapshot" "$(same "$CFG" "$FIX/config.json")"

echo
if [ "$fails" -eq 0 ]; then
	if [ "$KEEP" = 1 ]; then echo "pipeline scenario passed (sandbox kept: $SB)"
	else echo "pipeline scenario passed"; fi
	exit 0
fi
echo "$fails assertion(s) failed"
exit 1
