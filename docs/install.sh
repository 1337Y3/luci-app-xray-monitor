#!/bin/sh
# Install or upgrade luci-app-xray-monitor from the GitHub-hosted .ipk.
# Installs the package file directly (opkg install <file>), which does NOT need
# a signed opkg feed — so it works with the default `option check_signature` on.
# Deps (curl, ucode-mod-fs, ucode-mod-uci, luci-base, xray-core) are pulled from
# your normal OpenWrt feeds, so run `opkg update` once first if needed.
#
#   wget -qO- https://raw.githubusercontent.com/1337Y3/luci-app-xray-monitor/main/docs/install.sh | sh
set -e

BASE="https://raw.githubusercontent.com/1337Y3/luci-app-xray-monitor/main/docs"
ipk=$(wget -qO- "$BASE/Packages" 2>/dev/null | sed -n 's/^Filename: //p' | tail -n1)
[ -n "$ipk" ] || { echo "Could not read the package list from $BASE/Packages"; exit 1; }

tmp="/tmp/$ipk"
echo "Downloading $ipk ..."
wget -qO "$tmp" "$BASE/$ipk" || { rm -f "$tmp"; echo "Download failed"; exit 1; }
if ! tar -tzf "$tmp" >/dev/null 2>&1; then
	rm -f "$tmp"
	echo "Downloaded file is not a valid package (the feed may be updating right now)."
	echo "Wait a minute and run this again."
	exit 1
fi

echo "Installing (deps come from your normal feeds) ..."
opkg install --force-reinstall "$tmp"
rm -f "$tmp"
echo "Done — open LuCI: Services -> Xray Monitor."
