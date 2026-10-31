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
# F17 adds the rpcd backend's own contract, through a sandboxed copy of the
# rpcd script driving the sandboxed xray-sub above: config_get's "hash" (md5 of
# the file bytes, through a symlink, empty when the file is gone), config_save's
# optimistic lock (the right hash saves, a stale one is refused with conflict=1
# and touches nothing, no/empty hash keeps the old behavior), config_diff_text
# (semantic diff of the editor text vs the live config, invalid JSON named as
# such), and list/ACL consistency for every declared method.
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
# uci stub: keeps the sandbox off the live UCI. backup_keep=3 pins the prune
# budget so the counts below are deterministic; every other query comes back
# empty (sub_prefixes empty = legacy "all proxy outbounds are managed" mode).
case " $* " in
	*" get xray-monitor.sub.backup_keep "*) echo 3; exit 0 ;;
esac
exit 1
EOF
cat > "$SB/bin/opkg" <<'EOF'
#!/bin/sh
# opkg stub: even if a future case reaches self-update, nothing gets installed
echo "opkg $*" >> "${STUB_OPKG_LOG:-/dev/null}"
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
	"$SB/etc/init.d/xray" "$SB/etc/init.d/cron" "$SB/sub"
touch "$SB/lock/xray-monitor"

export TMPDIR="$SB/tmp"
export STUB_LOG="$SB/log/xray-test.log"
export STUB_HOOK_LOG="$SB/log/hooks.log"
export STUB_INITD_LOG="$SB/log/initd.log"
export STUB_PGREP_DOWN="$SB/flags/xray-down"
export STUB_OPKG_LOG="$SB/log/opkg.log"
: > "$STUB_LOG"; : > "$STUB_HOOK_LOG"; : > "$STUB_INITD_LOG"; : > "$STUB_OPKG_LOG"

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

echo
if [ "$fails" -eq 0 ]; then
	if [ "$KEEP" = 1 ]; then echo "pipeline scenario passed (sandbox kept: $SB)"
	else echo "pipeline scenario passed"; fi
	exit 0
fi
echo "$fails assertion(s) failed"
exit 1
