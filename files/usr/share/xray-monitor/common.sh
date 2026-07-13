# Shared helpers for xray-monitor scripts (xray-sub, xray-rules, xray-geodat).
# Sourced, not executed. POSIX sh / busybox.
SHARE=/usr/share/xray-monitor
STATE=/etc/xray-monitor
XRAY=/usr/bin/xray
APISRV="127.0.0.1:10085"
XMLOCK=/var/lock/xray-monitor.lock

config_file() {
	local f
	f=$(uci -q get xray.config.conffiles 2>/dev/null | awk '{print $1}')
	[ -f "$f" ] && { echo "$f"; return; }
	echo "/etc/xray/config.json"
}
CFG=$(config_file)
mkdir -p "$STATE"

data_dir() {
	local d; d=$(uci -q get xray.config.datadir 2>/dev/null)
	[ -n "$d" ] || d="/usr/share/xray"
	echo "$d"
}

# Stats API reachability probe (rc 0 = answering on 127.0.0.1:10085).
api_up() { "$XRAY" api statsquery --server="$APISRV" >/dev/null 2>&1; }

tproxy_port() {
	local p; p=$(uci -q get xray-monitor.fw.tproxy_port 2>/dev/null)
	[ -n "$p" ] || p=1200
	echo "$p"
}

rules_managed() { [ "$(uci -q get xray-monitor.rules.managed 2>/dev/null)" = "1" ]; }

# Routing mode (see genrules.uc):
#   lists    - xray-native: ONE tproxy inbound (fw.tproxy_port), domain/geo rules
#   inbounds - ruantiblock drives the steering (dst-IP nftset -> fwmark -> its own
#              tproxy port per list); xray is a plain inboundTag->outboundTag map,
#              one tproxy inbound per `inbound` section. xray-fw stays DOWN.
rules_mode() {
	local m; m=$(uci -q get xray-monitor.rules.mode 2>/dev/null)
	[ -n "$m" ] || m=lists
	echo "$m"
}

inbound_sids() {
	uci -q show xray-monitor 2>/dev/null | sed -n 's/^xray-monitor\.\([^.]*\)=inbound$/\1/p'
}

# Ports that MUST be bound for a managed config to count as healthy. In lists
# mode that is the single xray-fw tproxy port; in inbounds mode it is every
# enabled inbound section's port (1200 is never bound there, so checking
# tproxy_port would fail every apply and roll back a perfectly good config).
health_ports() {
	local sid p
	if [ "$(rules_mode)" = "inbounds" ]; then
		for sid in $(inbound_sids); do
			[ "$(uci -q get "xray-monitor.$sid.enabled" 2>/dev/null)" = "0" ] && continue
			p=$(uci -q get "xray-monitor.$sid.port" 2>/dev/null)
			[ -n "$p" ] && echo "$p"
		done
	else
		tproxy_port
	fi
}

port_listening() { netstat -ltn 2>/dev/null | grep -q ":$1 "; }

# All ports the live routing mode depends on are bound (vacuously true when
# managed routing is off).
managed_ports_up() {
	local p
	rules_managed || return 0
	for p in $(health_ports); do
		port_listening "$p" || return 1
	done
	return 0
}

# Mirror the routing state OUTSIDE the uci conffile.
#
# /etc/config/xray-monitor is a conffile, so a normal `opkg install` upgrade
# keeps it — but `opkg install --force-reinstall` does remove-then-install and
# drops conffiles, which would silently reset the mode and delete every inbound
# section (the LAN would then be steered to tproxy ports xray no longer binds).
# /etc/xray-monitor survives that (prerm keeps it on purpose), so snapshot the
# routing bits here after every successful change; postinst restores them if the
# conffile came back empty.
ROUTING_STATE="$STATE/routing.state"

save_routing_state() {
	local sid n p e en o
	{
		echo "# luci-app-xray-monitor routing state — auto-generated."
		echo "# Restored by postinst if /etc/config/xray-monitor is reset by a reinstall."
		echo "managed=$(uci -q get xray-monitor.rules.managed 2>/dev/null)"
		echo "mode=$(rules_mode)"
		for sid in $(inbound_sids); do
			n=$(uci -q get "xray-monitor.$sid.name")
			p=$(uci -q get "xray-monitor.$sid.port")
			e=$(uci -q get "xray-monitor.$sid.exit")
			en=$(uci -q get "xray-monitor.$sid.enabled")
			o=$(uci -q get "xray-monitor.$sid.order")
			[ -n "$n" ] && [ -n "$p" ] || continue
			echo "inbound=$n|$p|$e|${en:-1}|${o:-100}"
		done
	} > "$ROUTING_STATE.tmp" 2>/dev/null && mv "$ROUTING_STATE.tmp" "$ROUTING_STATE"
}

# One writer at a time across xray-sub apply / xray-rules apply / xray-geodat
# update / config-save: their backup->test->mv->restart->verify sections race
# otherwise (one caller's verify can "roll back" another's healthy restart).
# flock when available, mkdir lock (with stale-pid reap) as fallback.
lock_acquire() {
	if command -v flock >/dev/null 2>&1; then
		exec 9>"$XMLOCK" || return 0
		# BusyBox flock supports only [-sxun] FD — no -w timeout — so poll with
		# -n (non-blocking) rather than blocking with a deadline. Portable:
		# util-linux flock honours -n in FD mode too.
		local i=0
		while ! flock -n 9 2>/dev/null; do
			i=$((i + 1))
			[ "$i" -ge 180 ] && { echo "busy: another xray-monitor operation is running"; exit 1; }
			sleep 1
		done
		return 0
	fi
	local d="$XMLOCK.d" p i=0
	while ! mkdir "$d" 2>/dev/null; do
		p=$(cat "$d/pid" 2>/dev/null)
		if [ -n "$p" ] && [ ! -d "/proc/$p" ]; then rm -rf "$d"; continue; fi
		i=$((i + 1))
		[ "$i" -ge 180 ] && { echo "busy: locked by pid ${p:-?}"; exit 1; }
		sleep 1
	done
	echo $$ > "$d/pid"
	trap 'rm -rf "$XMLOCK.d"' EXIT INT TERM
}

# Keep the newest $1 (default 6) "$CFG.bak.*" backups, delete the rest.
# Only ever runs after a config change verified working (xray -test + restart).
# 6 (not 3): the nightly sub apply and rules/geodat changes each add backups,
# and history must cover at least a couple of days for rollback.
prune_backups() {
	local keep="${1:-6}" f n=0
	for f in $(ls -t "$CFG".bak.* 2>/dev/null); do
		n=$((n + 1))
		[ "$n" -le "$keep" ] && continue
		[ "$f" = "$CFG" ] && continue   # never the live config
		rm -f "$f"
	done
}

# After a config change + restart, confirm xray came back healthy; if not,
# restore the pre-change backup and restart. $1 = backup file to restore,
# $2 = 1 to also require the stats API to answer, $3 = max seconds to wait
# (default 15; polls 1s and returns early on success, so interactive saves
# stay fast while a cold start with a 70+ MB geosite.dat gets enough time).
# When managed routing is live, the tproxy inbound binding is part of
# "healthy" — a config that lost it would blackhole the LAN.
verify_or_rollback() {
	local bak="$1" need_api="$2" max="${3:-30}" i=0
	while [ "$i" -lt "$max" ]; do
		if pgrep -f "$XRAY run" >/dev/null 2>&1 \
			&& { [ "$need_api" != 1 ] || api_up; } \
			&& managed_ports_up; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	[ -f "$bak" ] && cp -a "$bak" "$CFG"
	/etc/init.d/xray restart >/dev/null 2>&1
	return 1
}

fetch_url() {  # <url> <user-agent> [header-dump-file]
	local hdr="${3:-/dev/null}"
	if command -v curl >/dev/null 2>&1; then curl -s -D "$hdr" -A "$2" --max-time 25 "$1"
	else uclient-fetch -q -O - -U "$2" -T 25 "$1"; fi
}
