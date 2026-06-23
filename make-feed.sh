#!/bin/sh
# Generate an opkg feed index (Packages + Packages.gz) from the .ipk files in docs/.
# The .ipk should be built on a router with build-ipk.sh (for correct root ownership)
# and copied into docs/. Run this on macOS or Linux; it only reads the .ipk files.
#   sh make-feed.sh
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
ls -l "$FEED"