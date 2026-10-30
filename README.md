# luci-app-xray-monitor

A LuCI app to **monitor and manage Xray** from the OpenWrt web UI. Tabs under
**Services → Xray Monitor**:

> **1.20 — the 1.18/1.19 routing stack is gone.** 1.18–1.19 tried to own the
> router's routing (lists, per-device bypass, per-list DNS, geo-rules, a tproxy
> firewall + watchdog, geodata auto-update, the ruantiblock migration). That
> line proved buggy and is dropped rather than patched: 1.20 is the pre-routing
> 1.17 code, so the app is back to **monitoring + subscriptions + the
> inbound→exit map** and leaves the firewall/routing to whatever already manages
> it (e.g. ruantiblock).
>
> Upgrading from 1.18/1.19: the Lists / Devices / Geodata / Inbounds pages, the
> `xray-tproxy` service and the `xray-fw` / `xray-geodat` /
> `migrate-ruantiblock` helpers disappear. **Run `xray-fw down` and
> `/etc/init.d/xray-tproxy stop; /etc/init.d/xray-tproxy disable` before
> upgrading** if you had the tproxy firewall on — nothing in 1.20 can tear it
> down for you. Your `config.json` is untouched, so the routing it already
> contains keeps working. `/etc/xray-monitor` and the extra `/etc/config/xray-monitor`
> sections (`fw`, `rules`, `geodat`, `inbound`, `list`, `device`) are left in
> place, inert; delete them by hand if you want them gone.

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

**Routing**
- Manage the tproxy **dokodemo-door inbounds**: add, rename, set the tproxy
  port, and pick each one's **exit** (any outbound or balancer) from a dropdown.
- Save validates with `xray -test`, backs up `config.json`, restarts xray, and
  auto-rolls-back on failure. The api inbound, balancers, outbounds and any
  other routing rules are left untouched.

**Config**
- A raw **`config.json` editor** with a **Test config** button (runs `xray -test`
  on the editor contents without saving) and **Save & apply** (validate → back up
  `config.json.bak.manual.*` → write → restart xray, auto-rollback if the test fails),
  plus **Reload from disk**.

**Balancers**
- **Combine outbounds** into a balancer: name it, pick members (checkboxes),
  choose a strategy (`leastPing` / `leastLoad` / `roundRobin` / `random`) and an
  optional fallback. Balancers appear as selectable exits in the Routing tab.
- `leastPing`/`leastLoad` members are auto-added to the **observatory**
  subjectSelector so they're probed. Same backup + `xray -test` + rollback.

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
| `/www/luci-static/resources/view/xray/config.js` | Config editor page |
| `/usr/share/xray-monitor/{parse,apply,diff,snapshot,status,routing,balancers,enable-api,render,probe}.uc` | ucode JSON transforms (render = shared outbounds renderer, probe = TCP probe backend) |
| `/usr/share/xray-monitor/xray-sub` | fetch/stage/apply helper (+ hourly cron) |
| `/etc/config/xray-monitor` | UCI config (sub URL, user-agent, cron) — conffile |
| `/etc/xray-monitor/overrides.json` | optional per-tag outbound overrides (see above) |
