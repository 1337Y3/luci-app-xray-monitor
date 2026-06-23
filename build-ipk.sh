#!/bin/sh
# Build luci-app-xray-monitor .ipk without the OpenWrt SDK.
# Produces an opkg-installable package from ./files and ./CONTROL.
# Runs on the router (BusyBox) or any POSIX sh with tar+gzip.
set -e

PKG="luci-app-xray-monitor"
VER="1.12-0"
ARCH="all"

HERE=$(cd "$(dirname "$0")" && pwd)
OUTDIR="${1:-$HERE}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/${PKG}.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---- staging ----
mkdir -p "$WORK/data" "$WORK/control"
cp -a "$HERE/files/." "$WORK/data/"
cp -a "$HERE/CONTROL/." "$WORK/control/"
chmod 0755 "$WORK/data/usr/libexec/rpcd/xray-monitor"
chmod 0755 "$WORK"/data/usr/share/xray-monitor/*.uc \
           "$WORK"/data/usr/share/xray-monitor/xray-sub
chmod 0755 "$WORK/control/postinst" "$WORK/control/prerm" "$WORK/control/postrm"

# ---- control metadata ----
SIZE=$(find "$WORK/data" -type f -print0 2>/dev/null | xargs -0 wc -c 2>/dev/null | awk 'END{print $1+0}')
cat > "$WORK/control/control" <<CONTROL_EOF
Package: ${PKG}
Version: ${VER}
Depends: luci-base, xray-core, curl, ucode-mod-fs
Section: luci
Architecture: ${ARCH}
Installed-Size: ${SIZE}
Maintainer: vinli
Description:  LuCI app to monitor and manage Xray: service status, live per-inbound
  and per-outbound traffic + rates (Stats API), per-outbound connectivity, rolling
  throughput graphs, a Remnawave subscription parser that auto-stages outbound
  updates, and exit-routing controls. Pages under Services -> Xray Monitor.
CONTROL_EOF

# ---- assemble .ipk (gzip-tar of debian-binary + control.tar.gz + data.tar.gz) ----
echo "2.0" > "$WORK/debian-binary"
( cd "$WORK/control" && tar -czf "$WORK/control.tar.gz" ./control ./conffiles ./postinst ./prerm ./postrm )
( cd "$WORK/data"    && tar -czf "$WORK/data.tar.gz" . )

OUT="$OUTDIR/${PKG}_${VER}_${ARCH}.ipk"
( cd "$WORK" && tar -czf "$OUT" ./debian-binary ./control.tar.gz ./data.tar.gz )

echo "Built: $OUT"
ls -l "$OUT"
