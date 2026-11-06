#!/bin/sh
# Build luci-app-xray-monitor .ipk without the OpenWrt SDK.
# Produces an opkg-installable package from ./files and ./CONTROL.
# Runs on the router (BusyBox) or any POSIX sh with tar+gzip.
# Shared staging/version lives in build-common.sh (also used by build-apk.sh).
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/build-common.sh"
stage_package "$HERE" "${1:-$HERE}"   # also installs the $WORK cleanup trap

# ---- control metadata ----
SIZE=$(find "$WORK/data" -type f -print0 2>/dev/null | xargs -0 wc -c 2>/dev/null | awk 'END{print $1+0}')
cat > "$WORK/control/control" <<CONTROL_EOF
Package: ${PKG}
Version: ${VER}
Depends: luci-base, xray-core, curl, ucode-mod-fs, ucode-mod-uci
Section: luci
Architecture: ${ARCH}
Installed-Size: ${SIZE}
Maintainer: vinli
Description:  LuCI app to monitor and manage Xray: service status, live per-inbound
  and per-outbound traffic + rates (Stats API), per-outbound connectivity, rolling
  throughput graphs, a Remnawave subscription parser that auto-stages outbound
  updates, and exit-routing controls. Pages under Services -> Xray Monitor.
CONTROL_EOF

# Force uid/gid 0 in the archives so the package installs as root no matter where
# it's built (Mac/Linux). BusyBox tar on a router already runs as root => 0/0.
if tar --version 2>/dev/null | grep -qi 'GNU tar'; then
	TAROWN='--owner=0 --group=0 --numeric-owner'
elif tar --version 2>/dev/null | grep -qi 'bsdtar'; then
	TAROWN='--uid 0 --gid 0 --numeric-owner'
else
	TAROWN=''
fi

# ---- assemble .ipk (gzip-tar of debian-binary + control.tar.gz + data.tar.gz) ----
echo "2.0" > "$WORK/debian-binary"
( cd "$WORK/control" && tar $TAROWN -czf "$WORK/control.tar.gz" ./control ./conffiles ./postinst ./prerm ./postrm )
( cd "$WORK/data"    && tar $TAROWN -czf "$WORK/data.tar.gz" . )

OUT="$OUTDIR/${PKG}_${VER}_${ARCH}.ipk"
( cd "$WORK" && tar $TAROWN -czf "$OUT" ./debian-binary ./control.tar.gz ./data.tar.gz )

echo "Built: $OUT"
ls -l "$OUT"
