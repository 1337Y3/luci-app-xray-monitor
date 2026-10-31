# luci-app-xray-monitor

A LuCI app to **monitor and manage Xray** from the OpenWrt web UI. Tabs under
**Services → Xray Monitor**:

> **1.22 — live hot-swap, balancer pins, E2E exit checks, config editor with
> optimistic locking, fetch-through-proxy.** Subscription outbound changes now
> apply **live via the xray API** (rmo/ado, no restart) whenever they are
> hot-swappable — anything else still restarts, with an honest reason shown
> (`changes beyond outbound membership`, `tag charset`, `default outbound`,
> …) and a snapshot+rollback fallback. The Balancers tab shows the **live**
> per-balancer pick and lets you **pin** a balancer to one outbound (applied
> live via `bo`, persisted in UCI, re-applied after every restart). The
> Overview gains an **E2E column**: a real body is pulled through every exit
> (204 probe for TTFB + a size-exact download) and judged `ok / stalled /
> fail / skipped` — a DPI freeze that kills transfers mid-body shows as
> `stalled`, not "reachable". The Config editor now detects concurrent edits
> (md5 optimistic lock: a stale save is refused with a reload hint instead of
> overwriting) and always shows a semantic diff before saving. Fetches and
> self-update downloads can go **through a proxy exit** (`fetch_via
> proxy|auto`) for routers whose own path to the panel/GitHub is blocked —
> the exit is picked from the freshest E2E results, and a configured proxy
> path that cannot be established fails honestly, never silently falling back
> to direct. Plus: timestamped `config.json` backups with pin/restore from
> the UI, symlink-safe snapshots, and flock(2)-based mutation locking.
>
> **1.21 — subscriptions hardened.** Fixes the `xray -test` breakage on save
> ("unsupported config file extension") — every temp config now lives as
> `config.json` inside a private `mktemp -d` dir and is installed atomically.
> A failed subscription fetch no longer deletes its exits; only outbounds
> tagged with a subscription's `<prefix>`/`<prefix>-*` are managed (manual
> proxies are preserved in a `// === local ===` block); panel-randomized
> fields (`spiderX` by default, `uci ...diff_ignore`) no longer read as
> changes; mutating commands serialize on a lock; the connectivity probe is a
> zero-payload TCP connect with ms latency; tags are sanitized (`[a-z0-9_-]`,
> collision suffixes) while existing tags stay stable; trojan/shadowsocks
> endpoints and IPv6 live-connections are detected; `self-update` verifies the
> downloaded package's SHA256. Golden tests + CI cover the ucode helpers.
>
> **1.20 — the 1.18/1.19 routing stack is gone.** 1.18–1.19 tried to own the
> router's routing and that line proved buggy; 1.20 returned to **monitoring +
> subscriptions + the inbound→exit map**, leaving firewall/routing to whatever
> already manages it. Coming from 1.18/1.19: run `xray-fw down` and stop/
> disable `xray-tproxy` **before** upgrading; the Lists / Devices / Geodata /
> Inbounds pages and their helpers disappear. `config.json` and
> `/etc/xray-monitor` are untouched.

**Overview**
- Service status: running/stopped, PID, uptime, version
- Per-**outbound** (VPS exits) upload/download totals + live ↑/↓ rates +
  a **connectivity status** column (reachable + latency / down / live)
- A per-outbound **Ping check** toggle: turn off the active TCP probe for an
  exit so it's never dialled. Use it for a "blown"/blocked server whose
  handshake draws a connection reset from your ISP — flip it off to stop poking
  that IP until your next config update. The status shows `○ ping off`; the
  passive live-connection check still runs (it only reads conntrack). The
  disabled set persists in UCI (`xray-monitor.sub.probe_disabled`). The toggles
  render on first paint (a probe-free `out_meta` call), so you can flip one
  before connectivity finishes loading.
- An **Auto-refresh ping** switch + **Refresh ping now** button: turn off
  auto-refresh and the page never probes exits on its own (one-shot checks stay
  on the button) — useful while investigating a suspect exit. Preference is
  per-browser (localStorage).
- Per-**inbound** (tproxy) upload/download totals + live ↑/↓ rates
- A **Reset counters** button (zeroes xray's cumulative totals via the Stats API)
- A **Validate config** button (runs `xray -test` and shows the result)
- A **Check for updates** button (compares the installed version to the feed and
  can download + install the latest `.ipk` in place)
- An **Enable Stats API** banner/button if the API isn't detected
- Traffic refreshes every 5 s; connectivity every 30 s while Auto-refresh ping is on
- An **E2E column** (end-to-end check): pulls a real body through every exit —
  a tiny always-fast 204 URL for TTFB and a size-exact download for
  throughput — and shows `ok / stalled / fail / skipped` per exit. `stalled`
  means bytes arrived and then the transfer died short of the expected size:
  the TSPU/DPI "reachable but useless" signature a bare TCP probe can't see.
  Probe-disabled exits are never dialled (`skipped`). Run it from the button
  (detached; progress visible while it runs) or schedule it
  (`uci set xray-monitor.sub.e2e_cron='1'` + an `e2e_schedule` cron
  expression — off by default, each run moves real traffic). Results stay in
  `/tmp/xray-monitor/e2e.json` and also feed the fetch-via exit choice.

**Graphs**
- Rolling per-outbound throughput charts (down/up), ~10 min window, 5 s
  resolution, drawn client-side (no collectd/RRD, no extra packages)

**Subscriptions** (Remnawave) — supports **several** subscriptions
- Add multiple subscriptions, each with a **prefix** and enable toggle. Every
  enabled subscription's servers are **combined** into the outbounds, written as
  its own block with a `// === subscription: <prefix> ===` header (a final
  `// === local ===` block holds `direct`/freedom and everything not owned by a
  subscription). Tags are `<prefix>-<location>`
  (e.g. `proxy-de-1`, `work-fi`); keep prefix `proxy` for your original sub so
  existing routing/balancers keep working. (xray and ucode both tolerate the
  `//` comments.)
- Parses each Remnawave subscription (Xray-JSON format) into outbounds with
  **stable, location-derived tags** (so routing keeps working across updates)
- A **scheduled fetch** (configurable cron — presets or a custom expression,
  toggle on/off) stages the latest servers. The tab shows what's pending
  (added / changed / removed); you click **Apply & restart xray** when ready
  (timestamped backup + `xray -test` + auto-rollback). **Fetch now** is also there.
- **Auto-apply** (opt-in): when a scheduled/manual fetch finds changes, it
  applies them and restarts xray automatically (same backup + test + rollback).
  All settings (URL, schedule, scheduled-fetch toggle, auto-apply) are on the tab.
- Only the subscription-managed proxy outbounds are spliced: tags equal to or
  under a configured subscription's `<prefix>` (`<prefix>-*`), for **all**
  subscriptions — enabled or disabled. Everything else — `direct`/freedom,
  inbounds, routing, balancers and proxy outbounds you added by hand — is left
  untouched and kept in the `// === local ===` block. **Never tag a manual
  outbound with a subscription prefix**: anything matching one is managed and
  is replaced or pruned by the next fetch/apply. Per-tag local overrides are
  supported ([overrides.json](#per-tag-overrides-etcxray-monitoroverridesjson)).
- **Churn control**: outbound fields the panel randomizes on every fetch (by
  default `streamSettings.realitySettings.spiderX`) are pruned from both sides
  before the diff, so two consecutive fetches with no panel-side changes report
  **0 pending** and auto-apply does not restart xray for nothing. The pruned set
  can be replaced via `uci add_list xray-monitor.sub.diff_ignore='<dot.path>'`
  (repeatable) + `uci commit xray-monitor`. Apply always writes the staged
  outbounds in full — ignoring a field only affects change detection.
- The server list shown is the **installed** set (from the live config); the
  diff shows what a pending fetch would change. State lives in
  `/etc/xray-monitor/` (persists across reboots/upgrades).
- **Hot-swap (live apply, on by default)**: when a fetch/apply only changes
  which outbounds a subscription owns — members added/removed, bodies
  unchanged — the running xray is reconciled **via its API** (`RemoveOutbound`
  / `AddOutbound`, batch timeout 10 s) with **no restart**; the status row
  shows `applied live (hot-swap) · -N/+M`. Anything not hot-swappable falls
  back to the classic restart pipeline, with the reason shown (changes beyond
  outbound membership, a tag outside `[A-Za-z0-9._-]`, the default outbound
  changing, API unavailable, running set ≠ config). A failed live attempt
  restores the snapshot and restarts + verifies unconditionally. Turn it off
  with `option hot_swap '0'` (always restart, the previous behavior).
- **Fetch through a proxy exit** (`fetch_via`): `direct` (default) | `proxy`
  (always through a temporary one-exit socks instance) | `auto` (try direct,
  retry through xray on failure) — for routers whose own path to the panel is
  blocked but whose exits reach it. The exit is chosen per run: your explicit
  `fetch_via_exit` tag, else the best `ok` exit from the freshest E2E results,
  else the first outbound the probe reports up. The same user agent, timeout
  and header capture apply on the proxied path, and the status row shows which
  transport actually moved bytes (`direct` / `via <tag>` / `direct, retried
  via <tag>`). Self-update downloads have their own switch
  (`fetch_via_update`; `opkg install` itself always stays local). A
  configured proxy path that cannot be established is an **honest failure** —
  never a silent direct fallback that would leak the fetch to a blocking ISP.

**Routing**
- Manage the tproxy **dokodemo-door inbounds**: add, rename, set the tproxy
  port, and pick each one's **exit** (any outbound or balancer) from a dropdown.
- Save validates with `xray -test`, backs up `config.json`, restarts xray, and
  auto-rolls-back on failure. The api inbound, balancers, outbounds and any
  other routing rules are left untouched.

**Config**
- A raw **`config.json` editor** with a **Test config** button (runs `xray -test`
  on the editor contents without saving) and **Save & apply**, plus
  **Reload from disk**.
- **Concurrent-edit protection**: the editor carries the md5 of the config it
  loaded; saving with a stale hash (the file changed on the router after you
  opened it — another admin, a subscription apply) is **refused** with a
  conflict notice instead of silently overwriting. Reload, re-apply your edit,
  save.
- **Mandatory diff before save**: saving always shows a semantic diff (added /
  removed / changed paths) of your text vs the live config; text that doesn't
  parse is named as invalid JSON rather than a generic failure. The save itself
  is the standard pipeline: `xray -test` → timestamped `manual` backup → atomic
  write → restart → verify, auto-rollback on failure.

**Backups**
- Every config write (apply, routing/balancers save, config editor, restore)
  leaves a timestamped `config.json.bak.<kind>.<ts>` next to the config
  (`auto` for subscription applies, `manual` for everything else; restore
  makes its own `manual` backup of what was live first).
- Browse the list with size/age, **pin** the ones you want to keep (pinned
  backups never count against `backup_keep` and are never pruned), **restore**
  one (it goes through the same validate-first pipeline with rollback), or
  delete. `backup_keep '0'` keeps everything.
- Snapshots are taken symlink-safe (`cp -pL`), so a symlinked `config.json`
  backs up the target's bytes, not the link.

**Balancers**
- **Combine outbounds** into a balancer: name it, pick members (checkboxes),
  choose a strategy (`leastPing` / `leastLoad` / `roundRobin` / `random`) and an
  optional fallback. Balancers appear as selectable exits in the Routing tab.
- `leastPing`/`leastLoad` members are auto-added to the **observatory**
  subjectSelector so they're probed. Same backup + `xray -test` + rollback.
- **Live view + sticky pins**: the tab reads each balancer's **live** state
  from the running xray (`xray api bi`): which outbound the strategy currently
  picks, right now. **Pin** a balancer to one member (applied live via
  `xray api bo` immediately — no restart — and persisted in UCI, so the pin is
  re-applied after every restart or config apply); **Unpin** releases it back
  to the strategy. Divergences are surfaced (saved pin ≠ running pick, stale
  balancer gone from the config, API down). Pins survive reboots; deleting the
  balancer or the outbound clears them with it.

It reads traffic from Xray's built-in **Stats API** over `127.0.0.1:10085`, and
detects per-outbound connectivity with an active **TCP probe** of each endpoint
plus a live-connection check via `/proc/net/nf_conntrack` (IPv6 included). The
probe is a **bare TCP connect — no payload, no TLS/HTTP handshake** — so it
can't trigger an ISP reset the way a ClientHello can. Backends, most precise
first: `ucode-mod-socket` (optional, in the feeds from OpenWrt 24.10; gives ms
latency), then `curl` (an `ftp://` connect that never sends a byte; up is read
off `time_connect`), then `ncat -z`. No secrets, no off-box exposure. Works
with any xray-core setup; outbound endpoints are discovered from the config
with `jsonfilter`, nothing is hardcoded.

Tested on OpenWrt 24.10 and 23.05 with `xray-core` 25.x. The connectivity
column needs one of the probe backends present; without any it shows "unknown"
(traffic/graphs still work).

## Per-tag overrides (`/etc/xray-monitor/overrides.json`)

Subscription outbounds sometimes need a local tweak the panel can't express —
`tcpFastOpen`, a `dialerProxy` chain, a different `fingerprint`. Since fetch
regenerates every managed outbound from the subscription response, hand edits
in `config.json` are **reverted on the next fetch/apply**. Put them in
`/etc/xray-monitor/overrides.json` instead: a JSON object keyed by the full
outbound **tag**, each value a partial outbound that is deep-merged into what
the panel delivered, before diffing and staging:

```json
{
	"proxy-de-frankfurt": {
		"streamSettings": {
			"realitySettings": { "fingerprint": "firefox" },
			"sockopt": { "tcpFastOpen": true, "dialerProxy": "manual-vps" }
		}
	}
}
```

- Objects merge recursively (`streamSettings` merges into the outbound's own);
  arrays and scalars are **replaced** whole.
- Keyed by final tag (`<prefix>-<base>`, e.g. `proxy-de-1`) — the tags shown
  in the Servers tab; they stay stable across fetches.
- Applied at fetch time, so overrides are part of the staged result, the
  pending diff, `xray -test` and backups — not a post-hoc patch.
- Unknown tags are ignored (create the entry after the first fetch, when the
  tag exists). The file is optional; delete or empty `{}` to disable.
- **Never tag a manual outbound with a subscription prefix** (see above) —
  overrides are the supported way to customize a subscription outbound.

## Install / upgrade (recommended — one line)

```sh
wget -qO- https://raw.githubusercontent.com/1337Y3/luci-app-xray-monitor/main/docs/install.sh | sh
```

This downloads the latest `.ipk` and installs it directly (`opkg install <file>`),
which works with the default `option check_signature` **on** — no feed signing,
no security changes. Re-run the same line any time to **upgrade**. It pulls from
the **GitHub Release** (`releases/latest/download/luci-app-xray-monitor.ipk` — a
single stable URL, robust on flaky links) and falls back to the raw feed.

Dependencies (`luci-base, xray-core, curl, ucode-mod-fs, ucode-mod-uci`) come from
your normal OpenWrt feeds, so run `opkg update` once first if any are missing
(`ucode` does the JSON work — no `jq` needed).

Fully manual fallback (e.g. if `raw.githubusercontent` is blocked but releases
aren't): download once and install the file —
```sh
wget -O /tmp/x.ipk https://github.com/1337Y3/luci-app-xray-monitor/releases/latest/download/luci-app-xray-monitor.ipk
opkg install /tmp/x.ipk
```

## Native opkg feed (optional, advanced)

You can add the repo as an opkg feed for native `opkg upgrade`, **but** OpenWrt's
default `option check_signature` refuses unsigned feeds — `opkg install` from the
feed then fails with *"not available from any configured src"*. This feed is
unsigned, so to use it you must turn off signature checking (affects **all**
feeds; HTTPS still protects transport integrity):

```sh
sed -i '/option check_signature/d' /etc/opkg.conf
echo 'src/gz xraymon https://1337y3.github.io/luci-app-xray-monitor' >> /etc/opkg/customfeeds.conf
opkg update && opkg install luci-app-xray-monitor
```

Most people should just use the one-line installer above instead.

### Maintaining the feed (all local — no SDK, no router)
1. Bump `VER` in `build-ipk.sh`.
2. `rm -f docs/*.ipk && sh build-ipk.sh docs` — builds straight into the feed.
   `build-ipk.sh` forces uid/gid 0 in the archive (GNU tar / bsdtar / BusyBox),
   so the package installs as root regardless of build host.
3. `sh make-feed.sh` — regenerates `docs/Packages[.gz]`.
4. `git commit` + `git push`. Routers pick it up on `opkg update && opkg upgrade`.

Then open LuCI → **Services → Xray Monitor** (hard-refresh the browser if the
menu doesn't appear immediately).

## Xray Stats API — enabled automatically on install

The app needs Xray's Stats API. **Install enables it for you**: postinst runs an
idempotent ucode merge that adds `stats` / `api` / `policy` + a localhost api
inbound (`127.0.0.1:10085`) + the api routing rule to `/etc/xray/config.json`,
validates with `xray -test`, backs up the old config (`config.json.bak.preapi.*`),
applies, and restarts xray. If nothing was missing it's a no-op (no restart). If
`xray -test` fails it rolls back and prints instructions instead.

Opt out by setting `option auto_enable_api '0'` in `/etc/config/xray-monitor`
before installing. If your API runs on a different port than 10085, edit
`API_SERVER` in `/usr/libexec/rpcd/xray-monitor`.

**If it didn't enable** (Overview shows a yellow "Enable Stats API" banner):
- click the banner button, or
- run it by hand to see the reason:
  `/usr/share/xray-monitor/xray-sub enable-api`
- check the log: `logread | grep xray-monitor`

Common causes: the `ucode-mod-fs` dependency wasn't installed (install it:
`opkg install ucode-mod-fs`), the xray config isn't at the path in
`uci get xray.config.conffiles`, or you installed a pre-1.7 build (auto-enable
was added in 1.7). `//` comments in the config are fine — both ucode's `json()`
and xray itself accept them. (Any rewrite of config.json by the app keeps the
generated `// === subscription … ===` / `// === local ===` block headers;
free-form comments elsewhere are dropped by the JSON round-trip.)

The merge it performs (equivalent, if you ever want to do it by hand):

```jsonc
"stats": {},
"api": { "tag": "api", "services": ["StatsService"] },
"policy": { "system": {
  "statsInboundUplink": true,  "statsInboundDownlink": true,
  "statsOutboundUplink": true, "statsOutboundDownlink": true
}},
// inbounds[] += { "tag": "api", "protocol": "dokodemo-door", "listen": "127.0.0.1",
//                 "port": 10085, "settings": { "address": "127.0.0.1" } }
// routing.rules[] prepend { "type": "field", "inboundTag": ["api"], "outboundTag": "api" }
```

## Uninstall

```sh
opkg remove luci-app-xray-monitor
```

(This removes only the app. It does not touch your `config.json`; remove the
`stats`/`api`/`policy` blocks yourself if you no longer want the API.)

## Rebuild from source

```sh
sh build-ipk.sh            # writes the .ipk next to the script
```

Pure data package (`Architecture: all`), so the SDK isn't required.

## Files installed

| Path | Purpose |
|------|---------|
| `/usr/libexec/rpcd/xray-monitor` | rpcd backend (ubus object `xray-monitor`) |
| `/usr/share/rpcd/acl.d/luci-app-xray-monitor.json` | ACL grant |
| `/usr/share/luci/menu.d/luci-app-xray-monitor.json` | menu entries (tabs) |
| `/www/luci-static/resources/view/xray/monitor.js` | Overview page |
| `/www/luci-static/resources/view/xray/graphs.js` | Graphs page |
| `/www/luci-static/resources/view/xray/subscription.js` | Subscription page |
| `/www/luci-static/resources/view/xray/routing.js` | Routing page |
| `/www/luci-static/resources/view/xray/balancers.js` | Balancers page |
| `/www/luci-static/resources/view/xray/backups.js` | Backups page |
| `/www/luci-static/resources/view/xray/config.js` | Config editor page |
| `/www/luci-static/resources/xray-diff.js` | shared diff renderer (line + semantic) |
| `/usr/share/xray-monitor/{parse,apply,diff,snapshot,status,routing,balancers,enable-api,render,probe}.uc` | ucode JSON transforms (render = shared outbounds renderer, probe = TCP probe backend) |
| `/usr/share/xray-monitor/hotswap.uc` | live-apply plan + ordered adds (hot-swap) |
| `/usr/share/xray-monitor/e2e.uc` | E2E exit-check verdicts / merge / summary |
| `/usr/share/xray-monitor/pickexit.uc` | choose the exit for proxied fetches (freshness-bounded e2e.json reader) |
| `/usr/share/xray-monitor/{balance,balance-cli}.uc` | live balancer view + override merge |
| `/usr/share/xray-monitor/{jsondiff,jsondiff-cli}.uc` | semantic path diff (editor diff, backup diff) |
| `/usr/share/xray-monitor/tmpxray.uc` | temporary one-exit socks instance builder (e2e, proxied fetch) |
| `/usr/share/xray-monitor/xray-sub` | fetch/stage/apply helper (+ hourly cron) |
| `/etc/config/xray-monitor` | UCI config (sub URL, user-agent, cron) — conffile |
| `/etc/xray-monitor/overrides.json` | optional per-tag outbound overrides (see above) |
