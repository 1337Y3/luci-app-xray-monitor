#!/bin/sh
# Build luci-app-xray-monitor .apk (apk-tools v3 package format, OpenWrt
# 25.06+ and apk-based snapshots) from the same ./files + ./CONTROL as the
# .ipk. Needs a FULL apk-tools >= 3.0 in PATH (`apk mkpkg`) - the router's
# own apk is built -Dminimal=true and drops mkpkg/mkndx, so build this on a
# dev host or in CI (see .github/workflows/build-feed.yml). Version mapping
# follows OpenWrt's include/package-defaults.mk: ipk "1.23-1" -> apk
# "1.23-r1" (apk rejects bare "-N" releases as invalid versions).
#
# Layout mirrors OpenWrt's include/package-pack.mk:
#   - conffiles ship as data files lib/apk/packages/<pkg>.conffiles(+_static)
#     (apk protects modified /etc files natively: new defaults land as *.apk-new)
#   - CONTROL postinst -> scripts post-install AND post-upgrade (apk runs the
#     latter on upgrades), prerm -> pre-deinstall with $1 forced to "remove"
#     (apk passes no opkg-style argument; pre-deinstall never runs on upgrade),
#     postrm -> post-deinstall verbatim
# Shared staging/version lives in build-common.sh (also used by build-ipk.sh).
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/build-common.sh"
stage_package "$HERE" "${1:-$HERE}"   # also installs the $WORK cleanup trap

command -v apk >/dev/null 2>&1 || { echo "ERROR: apk-tools not found in PATH" >&2; exit 1; }
# applet help exits 1; --version is the cheap "applet exists" probe
apk mkpkg --version >/dev/null 2>&1 || {
	echo "ERROR: this apk build has no mkpkg applet (the router's minimal apk drops it)" >&2
	exit 1
}

APKVER=$(printf '%s' "$VER" | sed -n 's/-\([0-9][0-9]*\)$/-r\1/p')
[ -n "$APKVER" ] || APKVER=$VER

# ---- conffiles as data files (apk layout) ----
CONFDIR="$WORK/data/lib/apk/packages"
mkdir -p "$CONFDIR"
cp "$WORK/control/conffiles" "$CONFDIR/$PKG.conffiles"
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
: > "$CONFDIR/$PKG.conffiles_static"
while IFS= read -r f; do
	[ -n "$f" ] || continue
	[ -f "$WORK/data$f" ] || { echo "ERROR: conffile $f missing from staging" >&2; exit 1; }
	printf '%s %s\n' "$f" "$(sha256 "$WORK/data$f")" >> "$CONFDIR/$PKG.conffiles_static"
done < "$WORK/control/conffiles"

# ---- maintenance scripts ----
# Bodies are reused verbatim from CONTROL; only the wrappers differ per
# script type (see the mapping notes in the header comment).
SCR="$WORK/scripts"; mkdir -p "$SCR"
cp "$WORK/control/postinst" "$SCR/post-install"
{
	echo '#!/bin/sh'
	echo '# apk runs post-upgrade (not post-install) when replacing the package;'
	echo '# body identical to post-install, PKG_UPGRADE=1 exported like OpenWrt.'
	echo 'export PKG_UPGRADE=1'
	sed '1{/^#!/d}' "$WORK/control/postinst"
} > "$SCR/post-upgrade"
{
	echo '#!/bin/sh'
	echo '# apk passes no opkg-style $1 and never runs pre-deinstall on upgrades,'
	echo '# so force the "remove" branch of the body below.'
	echo 'set -- remove'
	sed '1{/^#!/d}' "$WORK/control/prerm"
} > "$SCR/pre-deinstall"
cp "$WORK/control/postrm" "$SCR/post-deinstall"

# ---- metadata + assembly ----
# One-line description; keep in sync with build-ipk.sh's control block.
# Escape like OpenWrt's description_escape (backslash, ", $, backtick).
DESC='LuCI app to monitor and manage Xray: service status, live traffic + rates (Stats API), connectivity probes, graphs, Remnawave subscription parser, routing/balancers, config editor. Pages under Services -> Xray Monitor.'
DESC=$(printf '%s' "$DESC" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g' -e 's/`/\\`/g')

OUT="$OUTDIR/${PKG}-${APKVER}.apk"
set -- mkpkg -q \
	--info "name:$PKG" \
	--info "version:$APKVER" \
	--info "arch:noarch" \
	--info "description:$DESC" \
	--info "maintainer:vinli" \
	--info "url:https://github.com/1337Y3/luci-app-xray-monitor" \
	--info "tags:openwrt:section=luci" \
	--script "post-install:$SCR/post-install" \
	--script "post-upgrade:$SCR/post-upgrade" \
	--script "pre-deinstall:$SCR/pre-deinstall" \
	--script "post-deinstall:$SCR/post-deinstall" \
	--files "$WORK/data" \
	--output "$OUT" \
	--info "depends:luci-base xray-core curl ucode-mod-fs ucode-mod-uci"

# mkpkg records file uid/gid straight from the staging tree (OpenWrt runs it
# under fakeroot). As root a real chown suffices; otherwise wrap chown+mkpkg
# in ONE fakeroot session so mkpkg's stat sees the faked 0:0 ownership.
if [ "$(id -u)" -eq 0 ]; then
	chown -R 0:0 "$WORK/data"
	apk "$@"
elif command -v fakeroot >/dev/null 2>&1; then
	fakeroot -- sh -c 'chown -R 0:0 "$1" && shift && exec apk "$@"' sh "$WORK/data" "$@"
else
	echo "ERROR: mkpkg would bake $(id -un):$(id -gn) ownership into the package; run as root or install fakeroot" >&2
	exit 1
fi

echo "Built: $OUT (version $APKVER)"
ls -l "$OUT"
