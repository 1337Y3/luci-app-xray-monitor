#!/bin/sh
# Golden-output tests for the ucode helpers: parse / snapshot / diff / apply /
# routing / balancers (status.uc imports uci and is deliberately not covered).
# Runs wherever a POSIX sh and ucode exist - the CI job (ucode built from
# source) or a router directly (BusyBox ash):
#   sh tests/run.sh                    compare against tests/expected/
#   UPDATE_GOLDEN=1 sh tests/run.sh    regenerate the golden files
# With XRAY=/path/to/xray (or xray on PATH) every produced config is also
# validated with `xray -test`.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SHARE=$(cd "$HERE/../files/usr/share/xray-monitor" && pwd)
FIX="$HERE/fixtures"
EXP="$HERE/expected"
UC=${UC:-ucode}

command -v "$UC" >/dev/null 2>&1 || { echo "ucode not found in PATH"; exit 1; }
XRAY=${XRAY:-}
[ -x "$XRAY" ] || XRAY=$(command -v xray 2>/dev/null || true)

W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
xrayfails=0

# xraytest <name> <config.json> - optional validation of a produced config
xraytest() {
	[ -n "$XRAY" ] || return 0
	if "$XRAY" -test -format json -config "$2" >/dev/null 2>&1; then
		echo "PASS   xray -test: $1"
	else
		echo "FAIL   xray -test: $1"; xrayfails=$((xrayfails + 1))
	fi
}

check() {  # <name> <golden> <actual>
	if [ "${UPDATE_GOLDEN:-0}" = 1 ]; then
		cp "$3" "$2" && echo "REGEN  $1"
		return
	fi
	if cmp -s "$2" "$3"; then
		echo "PASS   $1"
	else
		echo "FAIL   $1"
		fails=$((fails + 1))
		diff -u "$2" "$3" 2>/dev/null | sed -n '1,20p'
	fi
}

echo "== parse (task 8: sanitize, collisions, tagmap stability)"
cp "$FIX/tagmap-proxy.json" "$W/tagmap.json"
"$SHARE/parse.uc" "$FIX/sub1.json" "$W/tagmap.json" "$FIX/overrides.json" proxy > "$W/parse-proxy.json" \
	|| { echo "FAIL   parse sub1 exited non-zero"; fails=$((fails + 1)); }
check "parse sub1 (tags, overrides deep-merge)" "$EXP/parse-proxy.json" "$W/parse-proxy.json"
check "parse tagmap (new bases sanitized, legacy kept)" "$EXP/tagmap-after.json" "$W/tagmap.json"
"$SHARE/parse.uc" "$FIX/sub1.json" "$W/tagmap.json" "$FIX/overrides.json" proxy > "$W/parse-proxy2.json"
check "parse sub1 stable across runs" "$W/parse-proxy.json" "$W/parse-proxy2.json"

"$SHARE/parse.uc" "$FIX/sub2.json" "$W/tagmap-work.json" "$FIX/overrides.json" work > "$W/parse-work.json"
check "parse sub2 (second prefix)" "$EXP/parse-work.json" "$W/parse-work.json"

echo "== snapshot (task 1: failed fetch keeps installed exits)"
"$SHARE/snapshot.uc" "$FIX/config.json" proxy > "$W/snapshot.json"
check "snapshot installed proxy-* exits" "$EXP/snapshot.json" "$W/snapshot.json"

echo "== diff (tasks 2+3: managed prefixes, ignore paths, reorder immunity)"
"$SHARE/diff.uc" "$FIX/staged-clean.json" "$FIX/config.json" proxy -- > "$W/diff-clean.json"
check "diff: key reorder + spiderX churn -> total 0" "$EXP/diff-clean.json" "$W/diff-clean.json"
"$SHARE/diff.uc" "$FIX/staged-nested.json" "$FIX/config.json" proxy -- > "$W/diff-nested.json"
check "diff: one nested field change -> changed" "$EXP/diff-nested.json" "$W/diff-nested.json"
"$SHARE/diff.uc" "$FIX/staged-clean.json" "$FIX/config.json" > "$W/diff-legacy.json"
check "diff without prefixes: manual outbound counts (legacy)" "$EXP/diff-legacy.json" "$W/diff-legacy.json"

# staged = both subscriptions' fresh parse output
printf '{"groups":[{"label":"proxy","outbounds":' > "$W/staged.json"
cat "$W/parse-proxy.json" >> "$W/staged.json"
printf '},{"label":"work","outbounds":' >> "$W/staged.json"
cat "$W/parse-work.json" >> "$W/staged.json"
printf '}]}' >> "$W/staged.json"
"$SHARE/diff.uc" "$W/staged.json" "$FIX/config.json" proxy work -- > "$W/diff-added.json"
check "diff: new sub added, manual-vps untouched (task 2)" "$EXP/diff-added.json" "$W/diff-added.json"

echo "== apply (tasks 2+7: prefixes, // block comments)"
"$SHARE/apply.uc" "$FIX/config.json" "$W/staged.json" "$W/apply.json" proxy work >/dev/null
check "apply: subscription groups + local block" "$EXP/apply.json" "$W/apply.json"
xraytest "apply output" "$W/apply.json"

echo "== routing / balancers (task 7: comments survive rewrites)"
"$SHARE/routing.uc" get "$FIX/config.json" > "$W/routing-get.json"
check "routing get" "$EXP/routing-get.json" "$W/routing-get.json"
"$SHARE/routing.uc" set "$FIX/config.json" "$FIX/routing-desired.json" "$W/routing-set.json" proxy work >/dev/null
check "routing set keeps // blocks" "$EXP/routing-set.json" "$W/routing-set.json"
xraytest "routing set output" "$W/routing-set.json"

"$SHARE/balancers.uc" get "$FIX/config.json" > "$W/balancers-get.json"
check "balancers get" "$EXP/balancers-get.json" "$W/balancers-get.json"
"$SHARE/balancers.uc" set "$FIX/config.json" "$FIX/balancers-desired.json" "$W/balancers-set.json" proxy work >/dev/null
check "balancers set keeps // blocks + observatory union" "$EXP/balancers-set.json" "$W/balancers-set.json"
xraytest "balancers set output" "$W/balancers-set.json"

echo
if [ "$fails" -eq 0 ] && [ "$xrayfails" -eq 0 ]; then
	echo "all tests passed${XRAY:+ (incl. xray -test)}"
else
	[ "$fails" -gt 0 ] && echo "$fails golden comparison(s) failed"
	[ "$xrayfails" -gt 0 ] && echo "$xrayfails xray -test run(s) failed"
	exit 1
fi
