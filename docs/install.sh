#!/bin/sh
# Install or upgrade luci-app-xray-monitor from the GitHub-hosted .ipk.
# Installs the package file directly (opkg install <file>), which does NOT need
# a signed opkg feed — so it works with the default `option check_signature` on.
# Deps (curl, ucode-mod-fs, ucode-mod-uci, luci-base, xray-core) come from your
# normal OpenWrt feeds, so run `opkg update` once first if any are missing.
#
#   wget -qO- https://raw.githubusercontent.com/1337Y3/luci-app-xray-monitor/main/docs/install.sh | sh

BASE="https://raw.githubusercontent.com/1337Y3/luci-app-xray-monitor/main/docs"
REL="https://github.com/1337Y3/luci-app-xray-monitor/releases/latest/download/luci-app-xray-monitor.ipk"

# fetch <url> -> stdout, trying curl/wget/uclient-fetch with retries
fetch() {
	url="$1"; i=1
	while [ "$i" -le 3 ]; do
		if command -v curl >/dev/null 2>&1; then
			out=$(curl -fsSL --max-time 30 "$url" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
		fi
		out=$(wget -qO- "$url" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
		i=$((i + 1)); sleep 2
	done
	return 1
}
# fetch_file <url> <dest>
fetch_file() {
	url="$1"; dst="$2"; i=1
	while [ "$i" -le 3 ]; do
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL --max-time 60 -o "$dst" "$url" 2>/dev/null && [ -s "$dst" ] && return 0
		fi
		wget -qO "$dst" "$url" 2>/dev/null && [ -s "$dst" ] && return 0
		i=$((i + 1)); sleep 2
	done
	return 1
}

tmp="/tmp/luci-app-xray-monitor.ipk"

# 1) preferred: the stable GitHub Release asset (single redirect, robust)
echo "Downloading latest package (GitHub Releases) ..."
if ! { fetch_file "$REL" "$tmp" && tar -tzf "$tmp" >/dev/null 2>&1; }; then
	# 2) fallback: the opkg feed (raw)
	echo "Releases unavailable — trying the feed ..."
	pkgs=$(fetch "$BASE/Packages") || { echo "Could not reach GitHub (Releases or feed) — it may be blocked/flaky here; try again in a minute."; exit 1; }
	ipk=$(printf '%s\n' "$pkgs" | sed -n 's/^Filename: //p' | tail -n1)
	[ -n "$ipk" ] || { echo "Package list had no entries (feed may be updating) — try again shortly."; exit 1; }
	fetch_file "$BASE/$ipk" "$tmp" || { rm -f "$tmp"; echo "Download failed — try again in a minute."; exit 1; }
	tar -tzf "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; echo "Downloaded file is not a valid package — try again shortly."; exit 1; }
fi

# Version of the .ipk we just downloaded (control.tar.gz -> ./control)
ipk_version() {
	d=$(mktemp -d) || return 1
	tar -xzf "$1" -C "$d" 2>/dev/null || { rm -rf "$d"; return 1; }
	tar -xzf "$d/control.tar.gz" -C "$d" 2>/dev/null || { rm -rf "$d"; return 1; }
	sed -n 's/^Version: //p' "$d/control" 2>/dev/null | head -n1
	rm -rf "$d"
}

# Refuse to go backwards. An older build does not understand a newer
# xray-monitor.rules.mode: it silently ignores it and regenerates the default
# routing model on the next apply, which blackholes a config that relies on the
# newer one. Set XRAYMON_ALLOW_DOWNGRADE=1 to override deliberately.
cur=$(opkg status luci-app-xray-monitor 2>/dev/null | sed -n 's/^Version: //p' | head -n1)
new=$(ipk_version "$tmp")
if [ -n "$cur" ] && [ -n "$new" ] && [ "$XRAYMON_ALLOW_DOWNGRADE" != "1" ]; then
	if ! opkg compare-versions "$new" '>=' "$cur" 2>/dev/null; then
		rm -f "$tmp"
		echo "Refusing to downgrade: installed $cur, package offers $new."
		echo "An older build ignores newer routing modes and would rewrite your config.json."
		echo "Override with: XRAYMON_ALLOW_DOWNGRADE=1 (only if you know what it does)."
		exit 1
	fi
fi

echo "Installing${new:+ $new} (deps come from your normal feeds) ..."
# Plain `opkg install` upgrades in place and runs the OLD package's prerm with
# "upgrade" (which skips the removal-only cleanup). Do NOT use --force-reinstall:
# it removes-then-installs, invoking prerm with "remove" AND dropping conffiles —
# that wipes /etc/config/xray-monitor (routing mode + inbound sections). postinst
# restores them from /etc/xray-monitor/routing.state, but don't rely on it.
# Same version already installed = no-op.
opkg install "$tmp"
rm -f "$tmp"
echo "Done — open LuCI: Services -> Xray Monitor."
