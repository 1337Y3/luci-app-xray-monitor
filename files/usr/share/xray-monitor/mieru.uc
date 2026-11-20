#!/usr/bin/ucode
// Pure mieru-client helpers for the Mieru tab. One UCI `mieru` section = one
// connection = one `mieru run` process (upstream's client serves exactly one
// activeProfile + one socks5 port per process). This file owns normalization
// and config emission so they are golden-testable WITHOUT ucode-mod-uci (CI
// builds plain ucode); the UCI bridge lives in mieru-uci.uc, which only
// serializes a section into the same conn shape and defers back here.
//   mieru.uc check <conn.json> [keep-username] [keep-password]
//       validate + normalize a connection (the UI's add/edit payload, or the
//       mieru-uci.uc bridge output) -> the normalized conn object on stdout:
//         { label, server_ip, server_domain, ports: ["2027/tcp","2012-2022/udp"],
//           username, password, mtu, multiplexing, handshake,
//           socks5_port, tproxy_port, rpc_port, logging, enabled }
//       Defaults: mtu 1400, MULTIPLEXING_LOW, HANDSHAKE_STANDARD, tproxy_port 0
//       (no transparent listener), logging ERROR (upstream's OpenWrt note:
//       keep logs small), enabled 1. rc 1 + a reason on stderr when invalid.
//       The optional keep-args implement "blank = keep" for credentials on
//       EDIT (the UI never echoes them back - same convention as sub-edit's
//       url): an empty username/password in the file falls back to the argv
//       value; at least one of the two must end up non-empty.
//   mieru.uc config <conn.json>
//       normalized conn -> the client config.json for `mieru run` (schema of
//       upstream's configs/examples/client_config.json, camelCase field
//       spelling): one profile named "default", user credentials, one server
//       (ipAddress/domainName, portBindings from the ports tokens),
//       rpcPort/socks5Port from the conn, socks5ListenLAN true (the port is
//       user-chosen and the stock OpenWrt firewall keeps WAN input closed).
//       rpc_port must be assigned (> 0) by then - the caller picks a free one.
//   mieru.uc tests <file>
//       slim dump of the per-connection test cache (see the merge form) as
//       {"<section-id>":{"ok":bool,"ts":N,"detail":""}}; absent/unparsable
//       file -> {}. Strings are re-emitted by ucode, so details stay escaped.
//   mieru.uc tests <file> <id> <0|1> <detail> [ts]
//       merge one test verdict into the cache file (prints the whole file,
//       the caller redirects to <path>.new and mv's it into place - the same
//       atomic-write shape as e2e.uc merge). id charset [A-Za-z0-9._-]; the
//       optional ts makes goldens deterministic, the live caller omits it
//       and gets time().
'use strict';
import { readfile } from 'fs';

function fail(msg) { warn(msg + '\n'); exit(1); }
function num(v) { return int(v ?? 0); }

function port_ok(p) {
	let s = '' + p;
	// match(), not regex.test() - ucode regexes are not objects with methods
	return (match(s, /^[0-9]+$/) && num(s) >= 1 && num(s) <= 65535);
}

// "<port>[-<port>]/<tcp|udp>" (either case) -> {lo, hi, proto}; the proto is
// normalized to the uppercase spelling upstream's portBindings expect.
// NOTE: no (?:...) groups - the 23.05 ucode regex engine rejects them.
function parse_ports_token(tok) {
	let m = match(uc('' + tok), /^([0-9]+)(-([0-9]+))?\/(TCP|UDP)$/);
	if (!m) return null;
	let lo = num(m[1]), hi = (m[3] != null) ? num(m[3]) : lo;
	if (lo < 1 || hi < lo || hi > 65535) return null;
	return { lo: lo, hi: hi, proto: m[4] };
}

function normalize(conn, keep_user, keep_pass) {
	if (type(conn) != 'object') fail('connection is not a JSON object');

	let label = '' + (conn.label ?? conn.name ?? '');
	if (!match(label, /^[A-Za-z0-9_.-]{1,32}$/) || label == '.' || label == '..')
		fail('invalid label (1-32 chars of A-Z a-z 0-9 . _ -)');

	let server_ip = '' + (conn.server_ip ?? '');
	let server_domain = '' + (conn.server_domain ?? '');
	if (server_ip && !match(server_ip, /^[0-9A-Fa-f.:%]{2,45}$/))
		fail('invalid server IP');
	if (server_domain && !match(server_domain, /^[A-Za-z0-9.-]{1,253}$/))
		fail('invalid server domain');
	if (!server_ip && !server_domain)
		fail('a server IP or domain is required');

	// ports arrive as the UCI list (array) or as a space-separated string
	let raw_ports = conn.server_ports ?? conn.ports ?? [];
	if (type(raw_ports) == 'string') raw_ports = split(trim(raw_ports), /\s+/);
	if (type(raw_ports) != 'array' || length(raw_ports) < 1)
		fail('at least one server port is required (e.g. 2027/tcp)');
	if (length(raw_ports) > 8) fail('too many server ports (max 8)');
	let ports = [];
	for (let i = 0; i < length(raw_ports); i++) {
		let p = parse_ports_token('' + raw_ports[i]);
		if (!p) fail('invalid port token: ' + raw_ports[i] + ' (want <port>[-<port>]/tcp|udp)');
		push(ports, p.lo == p.hi
			? sprintf('%d/%s', p.lo, p.proto)
			: sprintf('%d-%d/%s', p.lo, p.hi, p.proto));
	}

	// blank + keep-arg = keep the stored credential (edit path); add has no
	// keep-args, so a fresh connection still requires both
	let username = '' + (conn.username ?? '');
	if (!length(username) && length(keep_user ?? '')) username = keep_user;
	let password = '' + (conn.password ?? '');
	if (!length(password) && length(keep_pass ?? '')) password = keep_pass;
	if (!length(username) || !length(password)) fail('username and password are required');
	if (length(username) > 256 || length(password) > 256) fail('username/password too long');

	let mtu = num(conn.mtu ?? 1400);
	if (mtu == 0) mtu = 1400;
	if (mtu < 1280 || mtu > 1400) fail('mtu must be 1280-1400');

	let multiplexing = uc('' + (conn.multiplexing ?? 'MULTIPLEXING_LOW'));
	if (!match(multiplexing, /^MULTIPLEXING_(OFF|LOW|MIDDLE|HIGH)$/)) fail('invalid multiplexing level');

	let handshake = uc('' + (conn.handshake ?? 'HANDSHAKE_STANDARD'));
	if (!match(handshake, /^HANDSHAKE_(STANDARD|NO_WAIT)$/)) fail('invalid handshake mode');

	let socks5_port = num(conn.socks5_port);
	if (!port_ok(socks5_port)) fail('invalid socks5 port');

	let tproxy_port = num(conn.tproxy_port ?? 0);
	if (!port_ok(tproxy_port) && tproxy_port != 0) fail('invalid transparent port');

	let rpc_port = num(conn.rpc_port ?? 0);
	if (rpc_port != 0 && !port_ok(rpc_port)) fail('invalid rpc port');

	let logging = uc('' + (conn.logging ?? 'ERROR'));
	if (!match(logging, /^(DEBUG|INFO|WARNING|ERROR)$/)) fail('invalid logging level');

	return {
		label: label,
		server_ip: server_ip,
		server_domain: server_domain,
		ports: ports,
		username: username,
		password: password,
		mtu: mtu,
		multiplexing: multiplexing,
		handshake: handshake,
		socks5_port: socks5_port,
		tproxy_port: tproxy_port,
		rpc_port: rpc_port,
		logging: logging,
		enabled: (conn.enabled == '0' || conn.enabled == 0 || conn.enabled == false) ? 0 : 1
	};
}

// The mieru client config for one connection (upstream example schema).
function client_config(c) {
	if (c.rpc_port == 0) fail('rpc port not assigned (internal)');
	let bindings = [];
	for (let i = 0; i < length(c.ports); i++) {
		let m = match(c.ports[i], /^([0-9]+)(-([0-9]+))?\/(TCP|UDP)$/);
		if (!m) fail('internal: bad port token ' + c.ports[i]);
		push(bindings, (m[3] != null)
			? { portRange: m[1] + '-' + m[3], protocol: m[4] }
			: { port: num(m[1]), protocol: m[4] });
	}
	return {
		profiles: [{
			profileName: 'default',
			user: { name: c.username, password: c.password },
			servers: [{
				ipAddress: c.server_ip,
				domainName: c.server_domain,
				portBindings: bindings
			}],
			mtu: c.mtu,
			multiplexing: { level: c.multiplexing },
			handshakeMode: c.handshake
		}],
		activeProfile: 'default',
		rpcPort: c.rpc_port,
		socks5Port: c.socks5_port,
		socks5ListenLAN: true,
		loggingLevel: c.logging
	};
}

function load_tests(path) {
	let raw = readfile(path);
	if (raw) {
		let d = json(raw);
		if (type(d) == 'object') return d;
	}
	return {};
}

function slim_tests(d) {
	let out = {};
	for (let id in d) {
		let r = d[id];
		if (type(r) != 'object') continue;
		out[id] = { ok: (r.ok == true || r.ok == 1) ? true : false, ts: num(r.ts), detail: '' + (r.detail ?? '') };
	}
	return out;
}

if (ARGV[0] == 'check' && (length(ARGV) == 2 || length(ARGV) == 4)) {
	let raw = readfile(ARGV[1]);
	if (!raw) fail('cannot read ' + ARGV[1]);
	let conn = json(raw);
	if (type(conn) != 'object') fail('not a JSON object');
	print(sprintf('%J\n', normalize(conn, ARGV[2], ARGV[3])));
} else if (ARGV[0] == 'config' && length(ARGV) == 2) {
	let raw = readfile(ARGV[1]);
	if (!raw) fail('cannot read ' + ARGV[1]);
	let conn = json(raw);
	if (type(conn) != 'object') fail('not a JSON object');
	print(sprintf('%J\n', client_config(normalize(conn))));
} else if (ARGV[0] == 'tests' && length(ARGV) == 2) {
	print(sprintf('%J\n', slim_tests(load_tests(ARGV[1]))));
} else if (ARGV[0] == 'tests' && (length(ARGV) == 5 || length(ARGV) == 6)) {
	if (!match(ARGV[2], /^[A-Za-z0-9._-]+$/)) fail('invalid id');
	let d = load_tests(ARGV[1]);
	d[ARGV[2]] = { ok: (ARGV[3] == '1') ? true : false, ts: (length(ARGV) == 6) ? num(ARGV[5]) : time(), detail: ARGV[4] };
	print(sprintf('%J\n', d));
} else {
	warn('usage: mieru.uc check <conn.json> [keep-user keep-pass] | config <conn.json>' +
	     ' | tests <file> | tests <file> <id> <0|1> <detail> [ts]\n');
	exit(1);
}
