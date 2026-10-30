#!/usr/bin/ucode
// Build the throwaway config for `xray-sub tmpxray` (contract B2): a standalone
// xray with one socks inbound on 127.0.0.1 per requested outbound tag, routing
// pinned inboundTag -> outboundTag, log silenced, no api/stats/policy. The
// outbounds are copied verbatim from the live config - the requested tags plus
// their dependency chain (streamSettings.sockopt.dialerProxy, proxySettings.tag)
// so chained exits keep working. No inbounds/routing/dns of the live config are
// carried over; nothing here ever touches the live config.
//   tmpxray.uc <config.json> <out-path> <tag> <port> [<tag> <port> ...]
// Prints nothing on success; on an unknown/missing tag prints the reason to
// stderr and exits 1 (the caller then never starts xray).
'use strict';
import { readfile, writefile } from 'fs';

let cfg_path = ARGV[0], out_path = ARGV[1];
if (length(ARGV) < 4 || (length(ARGV) - 2) % 2 != 0) {
	warn('usage: tmpxray.uc <config.json> <out-path> <tag> <port> [...]\n');
	exit(1);
}

let cfg = json(readfile(cfg_path));
if (type(cfg) != 'object') { warn('not a JSON object\n'); exit(1); }
let obs = cfg.outbounds;
if (type(obs) != 'array' || !length(obs)) { warn('config has no outbounds\n'); exit(1); }

// Tags referenced by an outbound but declared elsewhere (chaining).
function dep_tags(o) {
	let deps = [];
	if (type(o.streamSettings) == 'object' && type(o.streamSettings.sockopt) == 'object'
	    && o.streamSettings.sockopt.dialerProxy)
		push(deps, o.streamSettings.sockopt.dialerProxy);
	if (type(o.proxySettings) == 'object' && o.proxySettings.tag)
		push(deps, o.proxySettings.tag);
	return deps;
}

let bytag = {};
for (let i = 0; i < length(obs); i++)
	if (obs[i].tag) bytag[obs[i].tag] = obs[i];

let selected = [], seen = {};
function add_tag(t) {
	if (seen[t]) return;
	if (!(t in bytag)) { warn('unknown outbound tag: ' + t + '\n'); exit(1); }
	seen[t] = true;
	push(selected, bytag[t]);
	let d = dep_tags(bytag[t]);
	for (let i = 0; i < length(d); i++) add_tag(d[i]);
}

let inbounds = [], rules = [], ports_seen = {};
for (let i = 2; i < length(ARGV); i += 2) {
	let t = ARGV[i], pa = ARGV[i + 1];
	if (seen[t]) { warn('duplicate tag: ' + t + '\n'); exit(1); }
	if (!match(pa, /^[0-9]+$/) || int(pa) < 1 || int(pa) > 65535 || ports_seen[int(pa)])
		{ warn('bad or duplicate port for ' + t + '\n'); exit(1); }
	let p = int(pa);
	ports_seen[p] = true;
	add_tag(t);
	push(inbounds, {
		tag: 'in-' + t, protocol: 'socks', listen: '127.0.0.1', port: p,
		settings: { auth: 'noauth', udp: true }
	});
	push(rules, { type: 'field', inboundTag: [ 'in-' + t ], outboundTag: t });
}

writefile(out_path, sprintf('%.2J\n', {
	log: { loglevel: 'none' },
	inbounds: inbounds,
	outbounds: selected,
	routing: { rules: rules }
}));
