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

echo "== jsondiff (F16: paths_diff via canonsig, order-independent)"
"$SHARE/jsondiff-cli.uc" "$FIX/jsondiff-a.json" "$FIX/jsondiff-b.json" > "$W/jsondiff-ab.json" \
	|| { echo "FAIL   jsondiff a->b exited non-zero"; fails=$((fails + 1)); }
check "jsondiff: add/remove/change on nested objects and arrays" "$EXP/jsondiff-ab.json" "$W/jsondiff-ab.json"
"$SHARE/jsondiff-cli.uc" "$FIX/jsondiff-a.json" "$FIX/jsondiff-reordered.json" > "$W/jsondiff-re.json" \
	|| { echo "FAIL   jsondiff reorder exited non-zero"; fails=$((fails + 1)); }
check "jsondiff: same object, keys reordered -> empty diff" "$EXP/jsondiff-re.json" "$W/jsondiff-re.json"

echo "== apply (tasks 2+7: prefixes, // block comments)"
"$SHARE/apply.uc" "$FIX/config.json" "$W/staged.json" "$W/apply.json" proxy work >/dev/null
check "apply: subscription groups + local block" "$EXP/apply.json" "$W/apply.json"
xraytest "apply output" "$W/apply.json"

echo "== overlapping prefixes (longest-prefix ownership: 'proxy' vs 'proxy-work')"
# The snapshot of a FAILED 'proxy' fetch must not capture 'proxy-work-*' exits -
# the other subscription's own staged group already carries them.
"$SHARE/snapshot.uc" "$FIX/config-overlap.json" proxy proxy proxy-work > "$W/snapshot-ov-p.json"
check "snapshot: failed 'proxy' keeps only its own exits" "$EXP/snapshot-ov-p.json" "$W/snapshot-ov-p.json"
"$SHARE/snapshot.uc" "$FIX/config-overlap.json" proxy-work proxy proxy-work > "$W/snapshot-ov-w.json"
check "snapshot: 'proxy-work' owns proxy-work-fi" "$EXP/snapshot-ov-w.json" "$W/snapshot-ov-w.json"
"$SHARE/diff.uc" "$FIX/staged-overlap.json" "$FIX/config-overlap.json" proxy proxy-work -- > "$W/diff-ov.json"
check "diff: overlapping prefixes, churn ignored -> total 0" "$EXP/diff-ov.json" "$W/diff-ov.json"
"$SHARE/apply.uc" "$FIX/config-overlap.json" "$FIX/staged-overlap.json" "$W/apply-ov.json" proxy proxy-work >/dev/null
check "apply: nested prefix keeps its own block" "$EXP/apply-ov.json" "$W/apply-ov.json"
xraytest "apply overlap output" "$W/apply-ov.json"
"$SHARE/routing.uc" set "$FIX/config-overlap.json" "$FIX/routing-desired-ov.json" "$W/routing-ov.json" proxy proxy-work >/dev/null
check "routing set: longest-prefix grouping" "$EXP/routing-ov.json" "$W/routing-ov.json"
xraytest "routing set overlap output" "$W/routing-ov.json"
# Same tag in two staged groups (what the pre-fix snapshot could produce):
# apply must refuse it, naming the tag - not emit a config xray -test rejects.
out=$("$SHARE/apply.uc" "$FIX/config-overlap.json" "$FIX/staged-dup.json" "$W/apply-dup.json" proxy proxy-work 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '"proxy-work-fi"'; then
	echo "PASS   apply: duplicate staged tag rejected, tag named"
else
	echo "FAIL   apply: duplicate staged tag rejected, tag named"; fails=$((fails + 1))
fi

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

echo "== enable-api (F0: StatsService + HandlerService + RoutingService)"
"$SHARE/enable-api.uc" "$FIX/config.json" "$W/eapi.json" 10085 proxy > "$W/eapi-changed.out" 2>/dev/null
check "enable-api: no api section -> changed" "$EXP/enable-api-changed.out" "$W/eapi-changed.out"
check "enable-api: adds stats/policy/inbound/rule + 3 services" "$EXP/enable-api.json" "$W/eapi.json"
xraytest "enable-api output" "$W/eapi.json"
"$SHARE/enable-api.uc" "$FIX/api-stats.json" "$W/eapi-stats.json" 10085 proxy > "$W/eapi-stats.out" 2>/dev/null
check "enable-api: StatsService only -> changed" "$EXP/enable-api-changed.out" "$W/eapi-stats.out"
check "enable-api: adds Handler+Routing, rest untouched" "$EXP/enable-api.json" "$W/eapi-stats.json"
"$SHARE/enable-api.uc" "$W/eapi.json" "$W/eapi-again.json" 10085 proxy > "$W/eapi-unchanged.out" 2>/dev/null
check "enable-api: all present -> unchanged" "$EXP/enable-api-unchanged.out" "$W/eapi-unchanged.out"
check "enable-api: unchanged rewrite is byte-identical" "$EXP/enable-api.json" "$W/eapi-again.json"

echo "== tmpxray config (F0: per-exit socks test instance)"
"$SHARE/tmpxray.uc" "$FIX/config.json" "$W/tmpxray.json" proxy-fi 10801 proxy-ch 10802
check "tmpxray: one socks inbound + pinned rule per tag" "$EXP/tmpxray.json" "$W/tmpxray.json"
xraytest "tmpxray output" "$W/tmpxray.json"
"$SHARE/tmpxray.uc" "$FIX/tmpxray-chain.json" "$W/tmpxray-chain.json" chain-a 12001
check "tmpxray: dialerProxy/proxySettings chain copied, unused not" "$EXP/tmpxray-chain.json" "$W/tmpxray-chain.json"
xraytest "tmpxray chain output" "$W/tmpxray-chain.json"
if "$SHARE/tmpxray.uc" "$FIX/config.json" "$W/tmpxray-bad.json" no-such-tag 10803 >/dev/null 2>&1; then
	echo "FAIL   tmpxray: unknown tag must be rejected"; fails=$((fails + 1))
else
	echo "PASS   tmpxray: unknown tag rejected"
fi

echo
if [ "$fails" -eq 0 ] && [ "$xrayfails" -eq 0 ]; then
	echo "all tests passed${XRAY:+ (incl. xray -test)}"
else
	[ "$fails" -gt 0 ] && echo "$fails golden comparison(s) failed"
	[ "$xrayfails" -gt 0 ] && echo "$xrayfails xray -test run(s) failed"
	exit 1
fi
