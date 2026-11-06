# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`luci-app-xray-monitor` — a LuCI app (OpenWrt web UI) that monitors and manages Xray: per-inbound/outbound traffic via Xray's Stats API, connectivity probes, Remnawave subscription parsing that splices outbounds into the xray `config.json`, live hot-swap via the xray API, balancers, backups, and a raw config editor. It is a pure data package (`Architecture: all`) — no OpenWrt SDK needed to build or test.

## Commands

```sh
sh build-ipk.sh                     # build the .ipk next to the script (version = VER= in build-common.sh)
sh build-apk.sh                     # build the .apk (apk-tools v3; needs full apk with mkpkg + root or fakeroot)
sh tests/run.sh                     # golden tests for the .uc helpers (needs ucode + ucode-mod-fs + POSIX sh)
UPDATE_GOLDEN=1 sh tests/run.sh     # regenerate tests/expected/ — always review the resulting diff
XRAY=/path/to/xray sh tests/run.sh  # additionally validate every produced config with `xray -test`
UC=/path/to/ucode sh tests/run.sh   # pick a specific ucode binary
sh tests/pipeline-scenario.sh       # sandboxed end-to-end scenario of xray-sub's write pipeline
KEEP_SB=1 sh tests/pipeline-scenario.sh <dir>  # keep the sandbox for review
```

- There is no per-test runner — `tests/run.sh` is one fast shell script that runs every .uc against `tests/fixtures/` and byte-compares (`cmp`) with `tests/expected/`.
- ucode has no Windows build; from the Windows dev machine the suite runs only in CI (or a Linux env). CI (`.github/workflows/build-feed.yml`) runs both test scripts on every PR/push to `main` on **two ucode legs**: the ucode shipped by OpenWrt 23.05 (pinned commit `1a8a0bcf`, the oldest supported interpreter) and current ucode master — everything under BusyBox ash with real `jshn`/`jsonfilter`.

### Packages and feeds (ipk + apk)

`VER` lives once in `build-common.sh` (shared staging for both builders). The `.ipk` targets opkg (OpenWrt ≤ 24.10); the `.apk` targets apk-based 25.06+:

- apk versions map ipk style through OpenWrt's own rule (`include/package-defaults.mk`): `1.23-1` → `1.23-r1` (apk rejects a bare `-N` release as an invalid version). `xray-sub`/rpcd normalize `-rN` back to `-N` before comparing, so `app_version`/update checks stay in ipk spelling everywhere.
- `build-apk.sh` mirrors OpenWrt's `include/package-pack.mk` recipe: `apk mkpkg` with conffiles shipped as data files (`lib/apk/packages/<pkg>.conffiles[.static]` — apk protects modified `/etc` files natively, writing new defaults as `*.apk-new`), postinst as both `post-install` and `post-upgrade` scripts, prerm as `pre-deinstall` with `$1` forced to `remove` (apk passes no opkg-style argument and never runs deinstall scripts on upgrades), postrm as `post-deinstall`. `mkpkg` records uid/gid from the staging tree, hence the root/fakeroot wrapper.
- Repeated `--info depends:` values OVERWRITE each other — all dependencies go in ONE space-separated value.
- The router's own apk is built `-Dminimal=true` and drops `mkpkg`/`mkndx`; building packages/indexes needs a host apk-tools ≥ 3.0 (CI builds v3.0.5, same as OpenWrt ships).
- `make-feed.sh` emits both indexes: `docs/Packages[.gz]` (opkg) and `docs/packages.adb` (`apk mkndx --allow-untrusted`; apk repository lines must be the FULL URL ending in `packages.adb`) plus a stable-named `.apk` + `.sha256` sidecar for self-update's feed fallback.
- The manager pick lives in ONE place: `xray-sub pkg_manager()` (exposed as the `pkg-manager` subcommand, consumed by the rpcd backend's `pkg_version()`). Whoever owns the installed package wins (`apk info -e` first — 25.06+ may carry an opkg compat package), then opkg, then apk.
- `xray-sub self-update` and `docs/install.sh` install `.ipk` via `opkg install --force-reinstall` / `.apk` via `apk add --allow-untrusted`, verifying the download against the `.sha256` sidecar (Release first, then feed) before handing it over.
- apk feed caveats (documented in README, verified): apk **silently ignores** an unsigned index (`apk update` exits 0 with an UNTRUSTED warning), and `apk upgrade` never updates a package installed from a file — `apk add <file>` pins it in `/etc/apk/world` by checksum. Updates on apk therefore go through the installer/self-update, which rewrite the pin.

### Release

Bump `VER` in `build-common.sh`, merge to `main`, push. CI's build job builds apk-tools, rebuilds `docs/` (`.ipk` + `.apk` + both indexes), auto-commits `docs/`, and publishes the GitHub Release (stable-named `.ipk` + `.apk`, each with a `.sha256` sidecar). Manual equivalent: `rm -f docs/*.ipk docs/*.apk docs/packages.adb && sh build-ipk.sh docs && sh build-apk.sh docs && sh make-feed.sh`.

## Layout

`files/` and `CONTROL/` are tarred into the .ipk verbatim by `build-ipk.sh` (which also chmods the executables — new executables must be added there):

- `files/www/luci-static/resources/view/xray/*.js` — LuCI client-side views (Overview, Graphs, Subscriptions, Routing, Balancers, Backups, Config); `../xray-diff.js` is the shared diff renderer. All UI logic is client-side and talks to ubus methods.
- `files/usr/libexec/rpcd/xray-monitor` — rpcd backend (POSIX sh + jshn): ubus object `xray-monitor`. **Every ubus method must also be listed in `files/usr/share/rpcd/acl.d/luci-app-xray-monitor.json`** (read vs write group; the scenario test checks list/ACL consistency). Tabs/menu live in `files/usr/share/luci/menu.d/`.
- `files/usr/share/xray-monitor/xray-sub` (~1700 lines, sh) — the workhorse: fetch/apply, subscription CRUD, routing/balancers/config save, `enable-api`, `e2e` exit checks, `tmpxray` (temporary one-exit socks xray for e2e and proxied fetches), backups, self-update, `cron-sync`. Every mutating command serializes on `flock /var/lock/xray-monitor` held on fd 3; tmpxray start/stop use their own mini-lock on fd 4. Children meant to outlive the script (tmpxray instance, watchdog) must close fd 3/4 or they hold the lock hostage.
- `files/usr/share/xray-monitor/*.uc` — ucode JSON transforms, each a standalone CLI covered by the golden tests. Exceptions: `render.uc` is a shared module imported by apply/routing/balancers (no shebang — the module compiler rejects `#`), and `status.uc` imports uci so it is deliberately not golden-tested.
- `files/etc/config/xray-monitor` — UCI defaults, options documented inline.

## Architecture

### Subscription pipeline (the core data flow)

fetch → `parse.uc` (subscription JSON → outbounds with stable `<prefix>-<base>` tags; `tagmap.json` keeps remark→base mapping stable across fetches; per-tag `overrides.json` deep-merged) → staged groups file → `diff.uc` (staged vs installed, after pruning `ignore=<dot.path>` churn fields from both sides — default `streamSettings.realitySettings.spiderX`, which the panel randomizes each fetch) → on apply, `hotswap.uc plan` picks one of two paths:

- **live hot-swap** (only managed-outbound membership/body changes): reconcile via `xray api rmo`/`ado`, no restart; on failure restore the snapshot and restart;
- **classic pipeline** (anything else, reason surfaced in the UI): timestamped backup → `xray -test` on a temp config → atomic install → restart → verify → auto-rollback on failure.

`apply.uc` / `routing.uc` / `balancers.uc` splice the config and re-emit the `outbounds` section through `render.uc`, preserving the `// === subscription: <prefix> ===` / `// === local ===` block comments (ucode's `%.2J` round-trip drops comments, so the section is rebuilt by hand — keep that layout intact).

**Ownership rule**: outbounds tagged `<prefix>` or `<prefix>-*` for any configured subscription prefix are managed (replaced/pruned by fetch/apply); longest prefix wins on overlap (`proxy` vs `proxy-work`); everything else is local and untouched. Never tag a manual outbound with a subscription prefix.

Note the argv order difference: `diff.uc` takes `<staged> <config>` (staged first), while `hotswap.uc plan` takes `<installed> <candidate>` (old config first).

### State locations

- `/etc/config/xray-monitor` (UCI) — settings, `subscription` sections, sticky balancer pins.
- `/etc/xray-monitor/` — persistent state: tagmap.json, staged.json, overrides.json.
- `/tmp/xray-monitor/` — volatile: `e2e.json` (+ run markers), tmpxray state.
- Xray Stats API expected at `127.0.0.1:10085` (`API_SERVER` in the rpcd backend); `enable-api.uc` merges it into configs lacking it (postinst runs it unless `auto_enable_api '0'`).

## Hard constraints

- **POSIX sh / BusyBox ash only** — no bashisms under `files/` or `tests/`; CI runs the whole suite under busybox ash.
- **ucode 23.05 compatibility**: that ucode drops a literal `--` from a script's ARGV, so ignore paths travel as `ignore=<path>` words (`diff.uc`, `hotswap.uc`), never after a `--` separator. Both CI ucode legs must pass.
- **Temp configs must be named `config.json`** inside a private `mktemp -d` dir — `xray -test` rejects other file extensions; install via atomic rename.
- Golden comparisons are byte-exact, including ucode `%J` spacing — regenerate with `UPDATE_GOLDEN=1` and inspect, don't hand-edit expected files.
- README.md is the user-facing documentation (features, the "Files installed" table) — update it together with behavior changes.
