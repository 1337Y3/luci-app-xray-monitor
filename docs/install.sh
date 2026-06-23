#!/bin/sh
# Install or upgrade luci-app-xray-monitor from the GitHub-hosted .ipk.
# Installs the package file directly (opkg install <file>), which does NOT need
# a signed opkg feed — so it works with the default `option check_signature` on.
# Deps (curl, ucode-mod-fs, ucode-mod-uci, luci-base, xray-core) come from your
# normal OpenWrt feeds, so run `opkg update` once first if any are missing.
#
#   wget -qO- https://raw.githubusercontent.com/1337Y3/luci-app-xray-monitor/main/docs/install.sh | sh

BASE="https://raw.githubusercontent.com/1337Y3/luci-app-xray-monitor/main/docs"

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

pkgs=$(fetch "$BASE/Packages") || { echo "Could not reach $BASE (GitHub may be blocked/flaky on this network) — try again in a minute."; exit 1; }
ipk=$(printf '%s\n' "$pkgs" | sed -n 's/^Filename: //p' | tail -n1)
[ -n "$ipk" ] || { echo "Package list had no entries (feed may be updating) — try again shortly."; exit 1; }

tmp="/tmp/$ipk"
echo "Downloading $ipk ..."
fetch_file "$BASE/$ipk" "$tmp" || { rm -f "$tmp"; echo "Download failed — try again in a minute."; exit 1; }
if ! tar -tzf "$tmp" >/dev/null 2>&1; then
	rm -f "$tmp"
	echo "Downloaded file is not a valid package (the feed may be updating right now) — try again shortly."
	exit 1
fi

echo "Installing (deps come from your normal feeds) ..."
opkg install --force-reinstall "$tmp"
rm -f "$tmp"
echo "Done — open LuCI: Services -> Xray Monitor."
