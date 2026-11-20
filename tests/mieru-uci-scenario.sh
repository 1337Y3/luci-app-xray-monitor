#!/bin/sh
# Real libuci regression: anonymous names change after commits; the app must
# pin legacy names and allocate independent names before deleting/adding rows.
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
REAL_UCI=$(command -v uci)
ucode -e 'import { cursor } from "uci"; cursor();' >/dev/null
SB=$(mktemp -d "${TMPDIR:-/tmp}/mieru-uci-test.XXXXXX")
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/config" "$SB/delta" "$SB/share" "$SB/run" "$SB/state" "$SB/lock"
export TESTCONF="$SB/config" TESTSAVEDIR="$SB/delta" REAL_UCI
cat > "$SB/bin/uci" <<'SH'
#!/bin/sh
exec "$REAL_UCI" -c "$TESTCONF" -t "$TESTSAVEDIR" "$@"
SH
cp -a "$HERE/files/usr/share/xray-monitor/." "$SB/share/"
# Explicit config-dir keeps the real ucode UCI bridge in the sandbox too.
mv "$SB/share/mieru-uci.uc" "$SB/share/mieru-uci-real.uc"
printf '#!/bin/sh\nexec ucode "%s/share/mieru-uci-real.uc" "$@" "%s/config"\n' "$SB" "$SB" > "$SB/share/mieru-uci.uc"
# No network daemon is launched; procd registration and generated configs
# are checked below against a dummy installed executable.
printf '#!/bin/sh\nexit 0\n' > "$SB/bin/mieru"
chmod 0755 "$SB/bin/uci" "$SB/bin/mieru" "$SB/share/"*.uc
export PATH="$SB/bin:$PATH"
sed -e "s|^SHARE=.*|SHARE=$SB/share|" \
    -e "s|^STATE=.*|STATE=$SB/state|" \
    -e "s|^LOCK=.*|LOCK=$SB/lock/config|" \
    -e "s|^TLOCK=.*|TLOCK=$SB/lock/tmpxray|" \
    -e "s|^TSTATE_DIR=.*|TSTATE_DIR=$SB/state|" \
    -e "s|^MIERU=.*|MIERU=$SB/bin/mieru|" \
    -e "s|^MIERU_INIT=.*|MIERU_INIT=$SB/service|" \
    -e "s|^MIERU_RUN=.*|MIERU_RUN=$SB/run|" \
    -e "s|^MTESTLOCK=.*|MTESTLOCK=$SB/lock/tests|" \
    "$HERE/files/usr/share/xray-monitor/xray-sub" > "$SB/sub"
sed -e "s|^SHARE=.*|SHARE=$SB/share|" \
    -e "s|^RUN=.*|RUN=$SB/run|" \
    -e "s|^MIERU=.*|MIERU=$SB/bin/mieru|" \
    "$HERE/files/etc/init.d/mieru-monitor" > "$SB/init"
# Only procd's process-launch API is stubbed: the actual service generates
# runtime files, enumerates IDs and configures the intended instance names.
cat > "$SB/service" <<SH
#!/bin/sh
. "$SB/init"
procd_open_instance() { echo "\$1" >> "$SB/instances"; }
procd_set_param() { :; }
procd_close_instance() { :; }
: > "$SB/instances"
start_service
SH
chmod 0755 "$SB/service"
fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1 (expected $2, got $3)"; }
sub() { sh "$SB/sub" "$@"; }
ids() { uci -X show xray-monitor | sed -n 's/^xray-monitor\.\([^.]*\)=mieru$/\1/p'; }
row() {
 cat <<ROW
config mieru
 option label '$1'
 option server_domain 'example.com'
 list server_ports '2027/tcp'
 option username 'fixture-user'
 option password 'fixture-password'
 option socks5_port '$2'
 option rpc_port '$3'
 option mtu '1400'
 option multiplexing 'MULTIPLEXING_LOW'
 option handshake 'HANDSHAKE_STANDARD'
 option logging 'ERROR'
 option enabled '1'
ROW
}
{ row first 1080 10090; row survivor 1081 10091; } > "$SB/config/xray-monitor"
chmod 0600 "$SB/config/xray-monitor"
old_first=$(ids | sed -n '1p'); survivor=$(ids | sed -n '2p')
printf '{"%s":{"ok":1,"ts":123}}\n' "$survivor" > "$SB/state/mieru-test.json"
cp "$SB/config/xray-monitor" "$SB/before"
sub mieru-get > "$SB/poll.json"
sh "$SB/service"
cmp -s "$SB/config/xray-monitor" "$SB/before" || fail 'poll/startup wrote UCI'
[ -f "$SB/run/$survivor.json" ] || fail 'legacy runtime key missing'
eq 'delete promotes survivor before commit' ok "$(sub mieru-del "$old_first")"
eq 'survivor ID stays unchanged' "$survivor" "$(ids)"
grep -q "config mieru '$survivor'" "$SB/config/xray-monitor" || fail 'survivor remains anonymous'
eq 'survivor credentials retained' fixture-password "$(uci get "xray-monitor.$survivor.password")"
[ -f "$SB/run/$survivor.json" ] || fail 'survivor runtime key changed'
grep -qx "mieru-$survivor" "$SB/instances" || fail 'survivor instance key changed'
[ ! -f "$SB/run/$old_first.json" ] || fail 'deleted runtime remains'
sub mieru-get > "$SB/poll.json"
eq 'cached verdict remains associated with survivor' true "$(jsonfilter -i "$SB/poll.json" -e "@.tests.$survivor.ok")"
cat > "$SB/add.json" <<'JSON'
{"label":"replacement","server_domain":"example.net","ports":["2027/tcp"],"username":"new-user","password":"new-password","socks5_port":1080}
JSON
for cycle in 1 2; do
 eq "add cycle $cycle" ok "$(sub mieru-add "$SB/add.json")"
 added=$(ids | sed "/^$survivor\$/d")
 case "$added" in mieru*) ;; *) fail 'new ID lacks its generated prefix';; esac
 grep -q "config mieru '$added'" "$SB/config/xray-monitor" || fail 'new ID is anonymous'
 [ "$added" != "${previous_added:-}" ] || fail 'new add reused previous ID'
 previous_added=$added
 [ "$added" != "$old_first" ] || fail 'deleted anonymous ID was reused'
 sh "$SB/service"
 [ -f "$SB/run/$survivor.json" ] && [ -f "$SB/run/$added.json" ] || fail 'runtime ID missing after add'
 eq 'runtime keeps survivor credentials' fixture-password "$(jsonfilter -i "$SB/run/$survivor.json" -e '@.profiles[0].user.password')"
 eq "delete cycle $cycle" ok "$(sub mieru-del "$added")"
 eq 'survivor remains stable through re-add' "$survivor" "$(ids)"
done
# The original ID remains usable by an already-open edit form after commits.
cat > "$SB/edit.json" <<'JSON'
{"label":"survivor","server_domain":"example.com","ports":["2027/tcp"],"username":"","password":"","socks5_port":1081}
JSON
eq 'edit original ID' ok "$(sub mieru-edit "$survivor" "$SB/edit.json")"
eq 'blank edit retains credentials' fixture-password "$(uci get "xray-monitor.$survivor.password")"
eq 'config remains private after UCI commits' '-rw-------' "$(ls -ld "$SB/config/xray-monitor" | cut -c1-10)"
echo 'real UCI Mieru scenario passed'
