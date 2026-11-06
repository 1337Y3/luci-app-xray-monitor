#!/bin/sh
# Generate package feed indexes from the built packages in docs/.
#   sh build-ipk.sh docs   &&   sh build-apk.sh docs   first.
# - opkg (OpenWrt <= 24.10):  docs/Packages + docs/Packages.gz from the .ipk
# - apk  (OpenWrt 25.06+):    docs/packages.adb via `apk mkndx` from the .apk,
#   plus a stable-named copy + .sha256 sidecar for `xray-sub self-update`'s
#   feed fallback (the .adb index is not parseable in POSIX sh).
# Run on macOS/Linux/CI; apk output needs apk-tools >= 3.0 with mkndx (not
# the router's minimal apk).
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
FEED="$HERE/docs"
PKGS="$FEED/Packages"

[ -d "$FEED" ] || { echo "no docs/ feed dir (build a .ipk into it first)"; exit 1; }
ls "$FEED"/*.ipk >/dev/null 2>&1 || { echo "no .ipk files in $FEED"; exit 1; }

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
md5of()  { if command -v md5sum   >/dev/null 2>&1; then md5sum "$1"   | awk '{print $1}'; else md5 -q "$1"; fi; }

: > "$PKGS"
for ipk in "$FEED"/*.ipk; do
	tmp=$(mktemp -d)
	tar -xzf "$ipk" -C "$tmp" ./control.tar.gz
	tar -xzf "$tmp/control.tar.gz" -C "$tmp" ./control
	cat "$tmp/control" >> "$PKGS"
	printf 'Filename: %s\n'   "$(basename "$ipk")" >> "$PKGS"
	printf 'Size: %s\n'       "$(wc -c < "$ipk" | tr -d ' ')" >> "$PKGS"
	printf 'SHA256sum: %s\n'  "$(sha256 "$ipk")" >> "$PKGS"
	printf 'MD5Sum: %s\n\n'   "$(md5of "$ipk")"  >> "$PKGS"
	rm -rf "$tmp"
done

gzip -c "$PKGS" > "$PKGS.gz"
echo "Wrote $PKGS and $PKGS.gz"

# ---- apk feed ----
stable="$FEED/luci-app-xray-monitor.apk"
if ls "$FEED"/luci-app-xray-monitor-*.apk >/dev/null 2>&1; then
	command -v apk >/dev/null 2>&1 || { echo "ERROR: .apk present but no apk-tools (mkndx) to index them"; exit 1; }
	set -- mkndx --allow-untrusted --output "$FEED/packages.adb"
	for apkf in "$FEED"/luci-app-xray-monitor-*.apk; do
		set -- "$@" "$apkf"
	done
	apk "$@"
	# stable name + sidecar consumed by the apk path of `xray-sub self-update`
	newest=$(ls -t "$FEED"/luci-app-xray-monitor-*.apk | head -n1)
	cp "$newest" "$stable"
	sha256 "$stable" > "$stable.sha256"
	echo "Wrote $FEED/packages.adb (+ stable-named apk + sha256 sidecar)"
fi
ls -l "$FEED"
