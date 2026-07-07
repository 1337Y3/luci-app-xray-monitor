# luci-app-xray-monitor

A LuCI app to **monitor and manage Xray** from the OpenWrt web UI. Tabs under
**Services → Xray Monitor**:

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
  `// === local ===` block holds `direct`/freedom). Tags are `<prefix>-<location>`
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
- Splices only the proxy outbounds; `direct`/freedom, inbounds, routing and
  balancers are left untouched. Per-tag local overrides are supported.
- The server list shown is the **installed** set (from the live config); the
  diff shows what a pending fetch would change. State lives in
  `/etc/xray-monitor/` (persists across reboots/upgrades).

**Lists**
- Named **domain/IP lists**, each mapped to an **exit** (outbound, balancer, or
  `direct` to bypass all proxies). Entries are one-per-line (bare domain = suffix
  match; `domain:`/`full:`/`keyword:`/`regexp:`/`geosite:` prefixes; IPv4/CIDR or
  `geoip:` become IP matchers; `#` comments). Lower **order** = matched earlier.
- Optional **per-list DNS**: pin those domains to an upstream (`IPv4[#port]`,
  comma for failover) via a dnsmasq `serversfile` — reloaded with SIGHUP.

**Devices**
- Per-LAN-device **bypass**. "Bypass everything (kernel)" drops the device from
  the tproxy firewall entirely (it never enters xray). Otherwise tick individual
  lists (and `registry`) it should go **direct** for, matched by source IP.

**Routing**
- **Transparent proxy** panel: master on/off toggle (kill switch) with live
  status badges (nft table / ip rule / watchdog / xray listening) — all LAN TCP
  is tproxy'd into a single xray inbound; UDP is untouched.
- **Routing globals**: default exit for unmatched traffic, and an **RKN registry**
  auto-route (`geosite:ru-blocked` / `geoip:ru-blocked` → a chosen exit).
- **Custom geo-rules**: match `geosite:`/`geoip:`/domain/source-IP/network → an
  exit (fields within a rule are AND-ed).
- All saves regenerate the managed `xm:`-tagged routing block, validate with
  `xray -test`, back up `config.json`, restart xray, and auto-roll-back on
  failure. Non-managed inbounds/rules, balancers and outbounds are preserved.

**Geodata**
- Download + **auto-update** `geoip.dat`/`geosite.dat` (default source:
  runetfreedom). Compares the published checksum first (no needless restart),
  validates every geo tag with a staged `xray -test` before cutover, keeps the
  previous files for one-click **rollback**, and runs on a cron schedule.

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
| `/www/luci-static/resources/view/xray/lists.js` | Lists page |
| `/www/luci-static/resources/view/xray/devices.js` | Devices page |
| `/www/luci-static/resources/view/xray/routing.js` | Routing page |
| `/www/luci-static/resources/view/xray/balancers.js` | Balancers page |
| `/www/luci-static/resources/view/xray/geodata.js` | Geodata page |
| `/www/luci-static/resources/view/xray/config.js` | Config editor page |
| `/usr/share/xray-monitor/{parse,apply,diff,status,genrules,rulescfg,gendns,balancers,enable-api}.uc` | ucode JSON transforms |
| `/usr/share/xray-monitor/common.sh` | shared shell helpers (lock, verify/rollback) |
| `/usr/share/xray-monitor/xray-sub` | subscription fetch/stage/apply helper (+ cron) |
| `/usr/share/xray-monitor/xray-rules` | managed-routing apply + list/device/rule setters |
| `/usr/share/xray-monitor/xray-fw` | tproxy nft firewall + failsafe watchdog + kill switch |
| `/usr/share/xray-monitor/xray-geodat` | geoip/geosite downloader + auto-update (+ cron) |
| `/usr/share/xray-monitor/migrate-ruantiblock` | one-shot ruantiblock → xray migration |
| `/etc/init.d/xray-tproxy` | procd service running the tproxy watchdog |
| `/etc/config/xray-monitor` | UCI config (sub, fw, rules, geodat) — conffile |

## Routing into xray & migrating from ruantiblock

By default the app only reads/edits routing you set up yourself. To have it own
routing — tproxy **all LAN TCP** into xray and drive it from the Lists/Devices/
Routing pages — enable *managed routing*. If you currently split traffic with
**ruantiblock** (dnsmasq nftset → fwmark → tproxy port), the one-shot migration
imports your user lists (deriving each exit from the port they target today),
installs geodata, disables ruantiblock (kept installed for rollback), and raises
the tproxy firewall:

```sh
/usr/share/xray-monitor/migrate-ruantiblock run       # migrate (auto-reverts on any failure)
/usr/share/xray-monitor/migrate-ruantiblock rollback  # full undo, re-enables ruantiblock
/usr/share/xray-monitor/xray-fw off                   # emergency kill switch (rules down, LAN direct)
```

Safety model: xray-down never blackholes the LAN — a watchdog (`/etc/init.d/xray-tproxy`)
removes the tproxy rules within ~5 s if xray stops or wedges, and an end-to-end
probe catches "listening but not relaying". UDP (Discord voice, QUIC, zapret) is
untouched — only TCP is tproxy'd. IPv4 only: if your LAN ever gets IPv6
(RA/DHCPv6), AAAA traffic bypasses these rules — keep the LAN v4-only or the
policy won't cover it. **Always verify DNS and Discord voice from a real LAN
client after migrating**, not just from the router.
