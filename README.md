# luci-app-xray-monitor

A LuCI app to **monitor and manage Xray** from the OpenWrt web UI. Tabs under
**Services → Xray Monitor**:

**Overview**
- Service status: running/stopped, PID, uptime, version
- Per-**outbound** (VPS exits) upload/download totals + live ↑/↓ rates +
  a **connectivity status** column (reachable + latency / down / live)
- Per-**inbound** (tproxy) upload/download totals + live ↑/↓ rates
- A **Reset counters** button (zeroes xray's cumulative totals via the Stats API)
- A **Validate config** button (runs `xray -test` and shows the result)
- An **Enable Stats API** banner/button if the API isn't detected
- Traffic refreshes every 5 s, connectivity every 30 s

**Graphs**
- Rolling per-outbound throughput charts (down/up), ~10 min window, 5 s
  resolution, drawn client-side (no collectd/RRD, no extra packages)

**Subscription** (Remnawave)
- Parses a Remnawave subscription (Xray-JSON format) into proxy outbounds with
  **stable, location-derived tags** (so routing keeps working across updates)
- A **scheduled fetch** (configurable cron — presets or a custom expression,
  toggle on/off) stages the latest servers. The tab shows what's pending
  (added / changed / removed); you click **Apply & restart xray** when ready
  (timestamped backup + `xray -test` + auto-rollback). **Fetch now** is also there.
- **Auto-apply** (opt-in): when a scheduled/manual fetch finds changes, it
  applies them and restarts xray automatically (same backup + test + rollback).
  All settings (URL, schedule, scheduled-fetch toggle, auto-apply) are on the tab.
- Splices only the proxy outbounds; `direct`/freedom, inbounds, routing and
  balancers are left untouched. Per-tag local overrides are supported.
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
(`curl`, falling back to `ncat`) plus a live-connection check via
`/proc/net/nf_conntrack`. No secrets, no off-box exposure. Works with any
xray-core setup; outbound endpoints are discovered from the config with
`jsonfilter`, nothing is hardcoded.

Tested on OpenWrt 24.10 with `xray-core` 25.x. The connectivity column needs
`curl` or `ncat` present; without either it shows "unknown" (traffic/graphs
still work).

## Install

```sh
# copy the .ipk to the router, then:
opkg install ./luci-app-xray-monitor_1.12-0_all.ipk
```

Depends: `luci-base, xray-core, curl, ucode-mod-fs` (all present on a stock
OpenWrt 24.10 with xray-core). The Subscription tab uses `curl` to fetch and
`ucode` to transform JSON — no `jq` needed.

## Install via opkg feed (recommended — gives `opkg upgrade`)

This repo publishes an opkg feed under `docs/` (served by GitHub Pages or
raw.githubusercontent). On each router, add the feed once:

```sh
echo 'src/gz xraymon https://1337y3.github.io/luci-app-xray-monitor' >> /etc/opkg/customfeeds.conf
opkg update
opkg install luci-app-xray-monitor
# later, to upgrade:
opkg update && opkg upgrade luci-app-xray-monitor
```

Using raw GitHub instead of Pages? Use this feed line:

```sh
echo 'src/gz xraymon https://raw.githubusercontent.com/1337Y3/luci-app-xray-monitor/main/docs' >> /etc/opkg/customfeeds.conf
```

(The router needs HTTPS support — `libustream-mbedtls` + `ca-bundle`, present on
stock images. Custom feeds aren't signature-checked.)

### Maintaining the feed
1. Build the `.ipk` on a router (root ownership): `sh build-ipk.sh /tmp` then
   copy it into `docs/` — or just bump `VER` in `build-ipk.sh` and rebuild.
2. Regenerate the index: `sh make-feed.sh` (writes `docs/Packages[.gz]`).
3. `git commit` + `git push`. Routers pick it up on `opkg update`.

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
was added in 1.7). The merge also needs the config to be plain JSON (no comments).

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
| `/usr/share/xray-monitor/{parse,apply,diff,status,routing,balancers,enable-api}.uc` | ucode JSON transforms |
| `/usr/share/xray-monitor/xray-sub` | fetch/stage/apply helper (+ hourly cron) |
| `/etc/config/xray-monitor` | UCI config (sub URL, user-agent, cron) — conffile |
