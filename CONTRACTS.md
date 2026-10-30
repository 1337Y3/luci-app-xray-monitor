# CONTRACTS — shared interfaces between tasks (authoritative)

Temporary file, removed at final integration. Every task agent must comply.
If a task needs to change a contract, the agent does NOT change this file —
it describes the proposal in its report and the orchestrator decides.

## Managed prefixes

`xray-sub` function `managed_prefixes` prints the prefixes of ALL configured
subscriptions (including disabled ones). They are passed to ucode scripts as
a JSON array in one argument. An outbound is managed ⇔ proxy protocol AND tag
`<prefix>` or `<prefix>-*`.

## Locking

Function `with_lock <cmd...>` in `xray-sub`, built on `lock /var/lock/xray-monitor`.
Internal invocations mark themselves `XRAYMON_LOCKED=1` and do NOT take the
lock again. Bounded wait (~55 s), then a clear error.

## Config write pipeline

Function `commit_config <new.json> <backup-kind> <need_api>` in `xray-sub`:
`xray -test` → backup `$CFG.bak.<kind>.<ts>` → copy to `$CFG.new` (no .json
extension) → atomic `mv` → restart → `verify_or_rollback` → `post_restart_hooks`.
ALL config writes go through it, nothing else writes `$CFG`.
`post_restart_hooks` is an empty extension-point function (filled by F15).

Extension for F14 (decided upfront by the orchestrator):
`commit_config <new.json> <backup-kind> <need_api> [mode]` where mode is
`restart` (default, as above) or `no-restart`: test → backup → atomic mv, but
NO restart/verify/hooks — the caller is responsible for making the running
xray match the file (e.g. via `xray api rmo/ado`) and falls back to a full
restart + verify_or_rollback on any error.

## Temp files

Only `d=$(mktemp -d) || exit 1`; the candidate config is `$d/config.json`;
the directory is removed on every exit branch. Rationale: a `*.json` next to
the real config gets picked up by xray started with `-confdir`.

## tmpxray

`xray-sub tmpxray start <tag>...` prints
`{"pid":N,"ports":{"<tag>":port}}`; `xray-sub tmpxray stop` stops it; the
process exits by itself after `XRAYMON_TMPXRAY_TTL` seconds (default 120).
A separate xray process: socks inbound on 127.0.0.1 per requested exit tag,
routing inboundTag → outboundTag, log none, no api/stats; outbounds are
copied from the live config; it waits until its ports are listening.

## E2E results

`/tmp/xray-monitor/e2e.json`:
`{"ts":N,"results":{"<tag>":{"status":"ok|stalled|fail|skipped","ttfb_ms":N,"bytes":N,"speed_bps":N,"ts":N}}}`.

## Diff JSON

ucode module `files/usr/share/xray-monitor/jsondiff.uc`:
`canonsig(v)` and `paths_diff(a, b)` → `{added:[path], removed:[path], changed:[path]}`.
JS module `files/www/luci-static/resources/xray-diff.js` (loaded via
`'require xray-diff'`) with line-based unified diff and semantic diff rendering.

## New UCI options (section `xray-monitor.sub` unless stated otherwise)

`diff_ignore` (list), `backup_keep`, `hot_swap`, `e2e_cron`, `e2e_schedule`,
`e2e_url_204`, `e2e_url_bytes`, `e2e_bytes`, `fetch_via`, `fetch_via_update`,
`fetch_via_exit`; sections `balancer_override` with options `balancer`,
`outbound`. Defaults are written to `files/etc/config/xray-monitor` by the
task that introduces the option.
