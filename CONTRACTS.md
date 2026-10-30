# CONTRACTS — actual helper interfaces + new feature contracts

Temporary orchestration file, removed at final integration. Part A records what
the code ACTUALLY does today (verified by audit on the P0/P1 base). Part B adds
the contracts the feature waves introduce. Agents: use these names, do not
duplicate or rename. Propose contract changes in your report, never edit this file.

## Part A — actual implementation (P0/P1 base)

Paths (variables at the top of `xray-sub`): `CFG=/etc/xray/config.json`,
`STATE=/etc/xray-monitor`, `SHARE=/usr/share/xray-monitor`, `XRAY=xray`,
`LOCK=/var/lock/xray-monitor`.

### Locking of mutations
There is no `with_lock` wrapper. The main `case "$1"` in `xray-sub` takes the
lock for: `fetch|apply|routing-set|balancers-set|config-save|enable-api|sub-add|
sub-del|sub-edit|set-cfg|cron-sync` with a bounded poll (`while ! lock -n
"$LOCK"` up to ~55 x sleep 1), sets `held=1`, and the `cleanup()` EXIT trap
releases it (`lock -u`). Read-only commands never lock. Internal recursion is
avoided by calling `do_apply` / `do_cron_sync` functions in-process instead of
re-executing `"$0"` (there is no `XRAYMON_LOCKED` env marker — do not invent one
without proposing it).

### Config write pipeline (a pattern, not one function)
Every writer follows the same sequence (see `do_apply`, `routing-set`,
`balancers-set`, `config-save`, `enable-api`):
1. `api_before=0; api_up && api_before=1` (where the stats API matters),
2. `bak="$CFG.bak.<kind>.$(date +%Y%m%d-%H%M%S)"; cp -a "$CFG" "$bak"`
   — kind is empty (auto) for apply/routing-set/balancers-set, `manual` for
   config-save, `preapi` for enable-api,
3. `stage_init()` → `STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xraymon.XXXXXX")`,
   candidate config is ALWAYS `$STAGE_DIR/config.json` (xray >= v25 picks the
   parser by file extension; `-format json` does not bypass that; a stray
   `*.json` next to $CFG would be picked up by `-confdir`),
4. transform via `apply.uc` / `routing.uc set` / `balancers.uc set` /
   `enable-api.uc` (each takes prefixes as trailing args),
5. `test_and_install <candidate>`: `xray -test -format json -config` → `cp` to
   `$CFG.new` (no .json) → atomic `mv` onto `$CFG`,
6. `/etc/init.d/xray restart`,
7. `verify_or_rollback <bak> <need_api>`: waits up to 5x1 s for
   `pgrep -f "$XRAY run"` (+ `api_up` when need_api=1), else restores the
   backup and restarts again,
8. `prune_backups [keep]` — keeps the newest N (currently default 3)
   `$CFG.bak.*` files, never the live config.
`cleanup()` (EXIT trap) removes `$STAGE_DIR`.

### Managed prefixes
`sub_prefixes()` prints the prefixes of ALL configured subscriptions (enabled
AND disabled), space-separated, passed to the ucode scripts as trailing argv.
Managed outbound ⇔ protocol in {vless, vmess, trojan, shadowsocks} AND tag ==
<prefix> or starts with `<prefix>-`. `diff.uc` / `apply.uc` / `routing.uc` /
`balancers.uc` / `enable-api.uc` all take `[prefix ...]` trailing args
(empty = legacy "every proxy outbound is managed").

### diff.uc
argv: `<staged-groups.json> <config.json> [prefix ...] [-- dot.path ...]`.
`canonsig(v)` = canonical order-independent serialization (object keys sorted).
`prune(o, path)` deletes one dot-path from an outbound copy; `body_of(o)`
prunes the ignore list (default: `streamSettings.realitySettings.spiderX`)
then canonsigs. Ignore list comes from `diff_ignore()` in xray-sub = UCI list
`xray-monitor.sub.diff_ignore`. Output `{added,removed,changed,total}`.

### render.uc (shared outbounds renderer, module — NO shebang)
Exports `render_outbounds(groups, locals)`, `render_config(cfg, groups, locals)`,
`split_outbounds(cfg, prefixes)` -> {groups, locals}, and
`emit(cfg, groups, locals, out_path)` (writes the file or prints when out_path
empty/'-'). Outbounds are rendered grouped per prefix with
`// === subscription: <prefix> ===` headers and a final `// === local ===`
block; non-managed outbounds keep config order inside the local block.
`apply.uc`, `routing.uc`, `balancers.uc`, `enable-api.uc` all emit through it.

### snapshot.uc (installed-exits snapshot)
argv `<config.json> [prefix]` → prints a `%J` array of the managed proxy
outbounds currently in the config. `fetch` uses it to re-stage the installed
exits of a subscription whose refetch failed (status `partial`).

### Probe / live-connections (rpcd backend)
`probe() <ip> <port>` prints `<up> <ms>`; backends in order: ucode socket
(`probe.uc`, needs ucode-mod-socket, 24.10+) → curl `ftp://` connect judged by
`time_connect` (works on 23.05) → `ncat -z` → `-1 0` (unknown). Bare TCP
connect, zero payload, ~3 s bound. `is_active()` greps `/proc/net/nf_conntrack`
for ESTABLISHED + `dst=`/`dport=`; `expand6()` normalizes IPv6 to the kernel's
zero-padded form; hostnames resolved with `resolveip` (-4 then -6).
Ping-check opt-out: UCI list `xray-monitor.sub.probe_disabled`
(`probe_disabled_list()`, rpcd method `probe_set`).

### Fetch / self-update
`fetch_url <url> <ua>` = `curl -s -D <hdrfile> -A <ua> --max-time 25` (+ a
uclient-fetch fallback); `subscription-userinfo` header parsed from the hdr
file. Self-update constants: `FEED=<repo>/main/docs`,
`REL=<releases>/latest/download/luci-app-xray-monitor.ipk`; integrity = SHA256
from `$REL.sha256`, fallback `SHA256sum:` from `$FEED/Packages` for the same
version; mismatch/absent → refuse. Scheduled fetch: `do_cron_sync()` manages
the `/etc/crontabs/root` line from UCI `xray-monitor.sub.cron` +
`cron_schedule`.

### enable-api.uc
argv `<config> <out> <port> [prefix ...]`. Today it only ensures
`api.services` contains `StatsService` and the api inbound listens on
127.0.0.1:<port>; prints `unchanged` / `changed`. api tag: `api`.

### UCI (files/etc/config/xray-monitor)
Section `xray-monitor sub`: `user_agent`, `cron`, `cron_schedule`,
`auto_apply`, `auto_enable_api` (+ list `probe_disabled`, list `diff_ignore`,
both defaulting in code). Subscriptions are `subscription` sections with
`prefix`, `url`, `enabled` (optional per-sub `user_agent`).

### Test infrastructure
`tests/run.sh` — flat golden suite: fixtures in `tests/fixtures/`, goldens in
`tests/expected/`, `UPDATE_GOLDEN=1 sh tests/run.sh` regenerates, `XRAY=<bin>`
adds `xray -test` validation of every produced config (auto-detected on PATH).
`status.uc` imports uci and is NOT covered. There is NO bootstrap script: CI
(.github/workflows/build-feed.yml, job `tests`) builds ucode-lang/ucode master
on ubuntu with integration modules off; the pinned openwrt-23.05 ucode version
(2024-07-11) is what the real router runs.
How to run on the router (no local ucode on the orchestration machine):
`git -c core.autocrlf=false archive --format=tar.gz -o /tmp/int.tar.gz integration`
(LF-clean!) → scp to router → extract to `/tmp/t-<id>/` → `sh tests/run.sh`
(and `XRAY=/usr/bin/xray sh tests/run.sh`). The router is LIVE: read-only
outside `/tmp/t-<id>/`, never restart services, never touch /etc or /usr.
Package build check works locally: extract the same archive and run
`sh build-ipk.sh /tmp/build-check`.

### UI / RPC surfaces
Views: `monitor.js`, `graphs.js`, `subscription.js`, `routing.js`,
`balancers.js`, `config.js` (LuCI JS, 23.05 APIs only; new strings via `_()`).
Menu: `files/usr/share/luci/menu.d/luci-app-xray-monitor.json`. ACL:
`files/usr/share/rpcd/acl.d/luci-app-xray-monitor.json`. rpcd backend
`files/usr/libexec/rpcd/xray-monitor` (ash): methods declared in its `list`
handler AND granted in the ACL — new methods need both.

## Part B — new contracts (introduced by the feature waves)

### B1. Pipeline extension points (F-prep)
`post_restart_hooks` — empty function in `xray-sub`, called after every
successful restart+verify (i.e. at the end of step 7 above, before
prune_backups/echo ok), under the same lock. "No-restart" mode for the write
pipeline: test → backup → atomic replace, WITHOUT restart/verify/hooks — the
caller then makes the running xray match by other means (xray api) and falls
back to a full restart + verify_or_rollback on any error. Existing call sites
keep today's behavior exactly.

### B2. tmpxray (F0)
`xray-sub tmpxray start <tag>...` prints
`{"pid":N,"ports":{"<tag>":port}}`; `xray-sub tmpxray stop` stops the process
and removes its files; the process exits by itself after
`XRAYMON_TMPXRAY_TTL` seconds (default 120). A separate xray: one socks
inbound per requested exit tag on 127.0.0.1, routing inboundTag → outboundTag,
log none, no api/stats; outbounds copied from the live config; config lives in
a mktemp dir as `config.json`; it waits for its ports to listen before
printing the JSON.

### B3. E2E results (F13 writes, F18 reads)
`/tmp/xray-monitor/e2e.json`:
`{"ts":N,"results":{"<tag>":{"status":"ok|stalled|fail|skipped","ttfb_ms":N,"bytes":N,"speed_bps":N,"ts":N}}}`.

### B4. Diff JSON (F16 introduces, F17 uses)
ucode module `files/usr/share/xray-monitor/jsondiff.uc`: `paths_diff(a, b)` →
`{added:[path], removed:[path], changed:[path]}` comparing via `canonsig`
(MOVE `canonsig` out of `diff.uc` into this module and re-import it there).
JS module `files/www/luci-static/resources/xray-diff.js` (loaded via
`'require xray-diff'`): line-based unified diff + semantic diff rendering.

### B5. New UCI options (section `xray-monitor.sub` unless stated otherwise)
`backup_keep`, `hot_swap`, `e2e_cron`, `e2e_schedule`, `e2e_url_204`,
`e2e_url_bytes`, `e2e_bytes`, `fetch_via`, `fetch_via_update`,
`fetch_via_exit`; sections `balancer_override` with options `balancer`,
`outbound`. The task introducing an option writes its default into
`files/etc/config/xray-monitor`.
