#!/bin/sh
# Shared staging for build-ipk.sh / build-apk.sh - sourced, never executed.
#
# stage_package <srcdir> <outdir-arg>:
#   - resolves OUTDIR (absolute; the outer tar/mkpkg runs from a temp cwd)
#   - creates $WORK/{data,control} from <srcdir>/{files,CONTROL}
#   - strips CR from text files (a Windows checkout with core.autocrlf=true
#     hands us CRLF, and BusyBox sh on the router refuses \r scripts - the
#     1.22-2 dist build died on its postinst that way); a file that looks
#     binary AND carries CR aborts the build rather than being corrupted
#   - bakes the package version into the UI (stale-view detection, see
#     staleVersion() in xray-diff.js) and sets executable modes
# The caller assembles the package from $WORK/data / $WORK/control; a cleanup
# trap for $WORK is installed here. VER lives here, once.

PKG="luci-app-xray-monitor"
VER="1.23-1"
ARCH="all"

stage_package() {
	HERE=$(cd "$(dirname "$0")" && pwd)
	SRCDIR="${1:-$HERE}"
	OUTDIR="${2:-$HERE}"
	mkdir -p "$OUTDIR"; OUTDIR=$(cd "$OUTDIR" && pwd)
	WORK=$(mktemp -d "${TMPDIR:-/tmp}/${PKG}.XXXXXX")
	trap 'rm -rf "$WORK"' EXIT

	mkdir -p "$WORK/data" "$WORK/control"
	cp -a "$SRCDIR/files/." "$WORK/data/"
	cp -a "$SRCDIR/CONTROL/." "$WORK/control/"
	CRFAIL="$WORK/crfail"
	find "$WORK/data" "$WORK/control" -type f -exec sh -c '
		if [ "$(tr -dc "\0" < "$2" | wc -c)" -eq 0 ]; then
			tr -d "\r" < "$2" > "$2.lf" && cat "$2.lf" > "$2" && rm -f "$2.lf"
		elif [ "$(tr -dc "\r" < "$2" | wc -c)" -ne 0 ]; then
			echo "ERROR: CR bytes in binary-looking file: $2" >&2
			: > "$1"
		fi
	' sh "$CRFAIL" {} \;
	if [ -e "$CRFAIL" ]; then
		echo "build aborted: refusing to strip CR from binary-looking files" >&2
		exit 1
	fi

	# Bake the package version into the UI so a stale cached view can detect
	# itself against status.app_version.
	find "$WORK/data/www" -type f -name '*.js' -exec sed -i "s/__XRAY_MONITOR_VER__/${VER}/g" {} \;
	chmod 0755 "$WORK/data/usr/libexec/rpcd/xray-monitor"
	chmod 0755 "$WORK"/data/usr/share/xray-monitor/*.uc \
	           "$WORK"/data/usr/share/xray-monitor/xray-sub
	chmod 0755 "$WORK/control/postinst" "$WORK/control/prerm" "$WORK/control/postrm"
}
