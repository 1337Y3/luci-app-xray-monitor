#!/usr/bin/ucode
// Serialize one UCI `mieru` section into the conn shape mieru.uc normalize()
// consumes. The uci import lives in this separate file (the same split as
// status.uc) so mieru.uc stays golden-testable under the plain CI ucode,
// which is built without integration modules.
//   mieru-uci.uc <section-id> [config-dir]
// Values are passed through verbatim (strings stay strings, list options
// arrive as arrays) - every default and validation belongs to mieru.uc, so
// the two files can never disagree about what a connection means. The
// optional config-dir goes straight into cursor() for the tests: some libuci
// builds ignore UCI_CONFIG_DIR, which would make a fixture-driven golden
// silently read the live /etc/config instead.
'use strict';
import { cursor } from 'uci';

if (length(ARGV) < 1 || length(ARGV) > 2) { warn('usage: mieru-uci.uc <section-id> [config-dir]\n'); exit(1); }
let uci = (length(ARGV) == 2) ? cursor(ARGV[1]) : cursor();
let s = uci.get_all('xray-monitor', ARGV[0]);
if (type(s) != 'object' || s['.type'] != 'mieru') {
	warn('no such mieru section: ' + ARGV[0] + '\n');
	exit(1);
}
printf('%J\n', {
	label: s.label ?? s['.name'],
	server_ip: s.server_ip ?? '',
	server_domain: s.server_domain ?? '',
	server_ports: s.server_ports ?? [],
	username: s.username ?? '',
	password: s.password ?? '',
	mtu: s.mtu ?? 0,
	multiplexing: s.multiplexing ?? '',
	handshake: s.handshake ?? '',
	socks5_port: s.socks5_port ?? 0,
	tproxy_port: s.tproxy_port ?? 0,
	rpc_port: s.rpc_port ?? 0,
	logging: s.logging ?? '',
	lan: s.lan ?? '0',
	enabled: s.enabled ?? '1'
});
