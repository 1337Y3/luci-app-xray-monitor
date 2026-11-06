# Package-manager pick for luci-app-xray-monitor - SOURCED by both the rpcd
# backend and xray-sub (keep it tiny: the rpcd re-sources it on every ubus
# call, including the 5 s status polls). Whoever OWNS the installed package
# wins: apk's db is asked first (25.06+ may carry an opkg compat package; a
# 24.10 box with an unused apk answers "not installed" and falls through),
# then opkg, then apk (fresh installs). `add`/`info`/`list` are all in the
# router apk's minimal applet set. Requires $PKG to be set by the sourcer.
pkg_manager() {  # -> stdout: apk | opkg; rc 1 = neither found
	if command -v apk >/dev/null 2>&1 && apk info -e "$PKG" >/dev/null 2>&1; then
		echo apk
	elif command -v opkg >/dev/null 2>&1; then
		echo opkg
	elif command -v apk >/dev/null 2>&1; then
		echo apk
	else
		return 1
	fi
}
