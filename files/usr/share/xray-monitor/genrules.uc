#!/usr/bin/ucode
// Generate the managed routing block of config.json from UCI state
// (xray-monitor: fw/rules globals + list/device/georule sections) and the
// per-list entry files /etc/xray-monitor/lists/<name>.lst.
//
//   genrules.uc get <config.json>            -> JSON payload for the UI views
//   genrules.uc set <config.json> <out-path> -> rewritten config + {"ok":true,"warnings":[...]}
//
// Managed artifacts are identified by ruleTag prefix "xm:" (rules), tag
// "tproxy-in" (single tproxy inbound) and tag "xm-probe" (watchdog probe
// inbound); everything else in the config is preserved verbatim.
// `set` is a hard error unless uci xray-monitor.rules.managed == '1' — this is
// the master gate that keeps the package inert until migration flips it, and
// makes rollback one-step-durable (clearing it disables the nightly re-gen).
'use strict';
import { readfile, writefile, stat } from 'fs';
import { cursor } from 'uci';

let action = ARGV[0];
let cfg_path = ARGV[1];
let out_path = ARGV[2];

const STATE = '/etc/xray-monitor';
let ctx = cursor();

function uget(sec, opt, def) {
	let v = ctx.get('xray-monitor', sec, opt);
	return (v == null || v == '') ? def : v;
}

function ulist(v) {
	if (v == null) return [];
	return (type(v) == 'array') ? v : [ v ];
}

let cfg = json(readfile(cfg_path));

// ---- UCI state ------------------------------------------------------------

let fw = {
	tproxy_port: int(uget('fw', 'tproxy_port', 1200)),
	probe_port:  int(uget('fw', 'probe_port', 1201)),
	mark_out:    int(uget('fw', 'mark_out', 256))
};
let globals = {
	managed:          uget('rules', 'managed', '0') == '1',
	default_exit:     uget('rules', 'default_exit', 'direct'),
	registry_enabled: uget('rules', 'registry_enabled', '0') == '1',
	registry_exit:    uget('rules', 'registry_exit', 'direct'),
	registry_geosite: uget('rules', 'registry_geosite', ''),
	registry_geoip:   uget('rules', 'registry_geoip', '')
};

function by_order(a, b) {
	let d = int(a.order) - int(b.order);
	if (d != 0) return d;
	return (a.name < b.name) ? -1 : ((a.name > b.name) ? 1 : 0);
}

let lists = [];
ctx.foreach('xray-monitor', 'list', function(s) {
	push(lists, {
		name: s.name ?? '', exit: s.exit ?? 'direct', dns: s.dns ?? '',
		enabled: (s.enabled ?? '1') == '1', order: int(s.order ?? 100)
	});
});
sort(lists, by_order);

let devices = [];
ctx.foreach('xray-monitor', 'device', function(s) {
	push(devices, {
		name: s.name ?? '', ip: s.ip ?? '',
		bypass_all: (s.bypass_all ?? '0') == '1',
		bypass: ulist(s.bypass),
		enabled: (s.enabled ?? '1') == '1'
	});
});

let georules = [];
ctx.foreach('xray-monitor', 'georule', function(s) {
	push(georules, {
		name: s.name ?? '', enabled: (s.enabled ?? '1') == '1',
		order: int(s.order ?? 100),
		domain: ulist(s.domain), ip: ulist(s.ip), source: ulist(s.source),
		network: s.network ?? '', exit: s.exit ?? 'direct'
	});
});
sort(georules, by_order);

// ---- entry files ------------------------------------------------------------

// One entry per line, '#' comments (ruantiblock user_lists style).
// bare domain -> "domain:<d>" (suffix match, same semantics ruantiblock had);
// domain:/full:/regexp:/keyword:/geosite: pass through as domain matchers;
// IPv4/CIDR/geoip: become ip matchers.
function parse_entries(name) {
	let doms = [], ips = [];
	let raw = readfile(STATE + '/lists/' + name + '.lst');
	if (raw == null) return { domains: doms, ips: ips };
	for (let line in split(raw, "\n")) {
		line = trim(line);
		if (!length(line) || substr(line, 0, 1) == '#') continue;
		if (match(line, /^(domain|full|regexp|keyword|geosite):/)) push(doms, line);
		else if (match(line, /^geoip:/)) push(ips, line);
		else if (match(line, /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(\/[0-9]{1,2})?$/)) push(ips, line);
		else push(doms, 'domain:' + line);
	}
	return { domains: doms, ips: ips };
}

// ---- config enumeration -----------------------------------------------------

function balancer_tags() {
	let b = {}, arr = (cfg.routing && cfg.routing.balancers) ? cfg.routing.balancers : [];
	for (let i = 0; i < length(arr); i++) b[arr[i].tag] = 1;
	return b;
}

function exit_map() {
	let known = {}, obs = cfg.outbounds ?? [];
	for (let i = 0; i < length(obs); i++) known[obs[i].tag] = 'outbound';
	let bals = balancer_tags();
	for (let t in bals) known[t] = 'balancer';
	known['direct'] = known['direct'] ?? 'outbound';   // `set` guarantees it exists
	return known;
}

function geodata_paths() {
	let d = ctx.get('xray', 'config', 'datadir');
	if (d == null || d == '') d = '/usr/share/xray';
	return { geosite: d + '/geosite.dat', geoip: d + '/geoip.dat' };
}

function geodata_present() {
	let p = geodata_paths();
	return stat(p.geosite) != null && stat(p.geoip) != null;
}

// ---- get ---------------------------------------------------------------------

if (action == 'get') {
	let known = exit_map();
	let warnings = [];
	let out_lists = [];
	for (let l in lists) {
		let e = parse_entries(l.name);
		if (l.enabled && !known[l.exit])
			push(warnings, sprintf("list '%s': exit '%s' missing (would fall back)", l.name, l.exit));
		push(out_lists, {
			name: l.name, exit: l.exit, dns: l.dns, enabled: l.enabled, order: l.order,
			counts: { domain: length(e.domains), ip: length(e.ips) }
		});
	}
	for (let g in georules)
		if (g.enabled && !known[g.exit])
			push(warnings, sprintf("georule '%s': exit '%s' missing (would fall back)", g.name, g.exit));
	if (globals.registry_enabled && !known[globals.registry_exit])
		push(warnings, sprintf("registry exit '%s' missing", globals.registry_exit));
	if (!known[globals.default_exit])
		push(warnings, sprintf("default exit '%s' missing", globals.default_exit));
	if ((globals.registry_enabled || length(georules)) && !geodata_present())
		push(warnings, 'geodata (.dat) files not installed — run a Geodata update');

	let exits = [];
	for (let t in keys(known)) push(exits, { tag: t, kind: known[t] });

	printf('%J\n', {
		managed: globals.managed,
		tproxy_port: fw.tproxy_port, probe_port: fw.probe_port,
		default_exit: globals.default_exit,
		registry: {
			enabled: globals.registry_enabled, exit: globals.registry_exit,
			geosite: globals.registry_geosite, geoip: globals.registry_geoip
		},
		lists: out_lists, devices: devices, georules: georules,
		exits: exits, geodata_present: geodata_present(), warnings: warnings
	});
}
else if (action == 'set') {

if (out_path == null) die('set requires an out-path');
if (!globals.managed) die('managed routing is off (uci xray-monitor.rules.managed != 1) — refusing to rewrite routing');

let warnings = [];

// -- inbounds: keep non-managed (api, socks-dns, ...), sweep managed tproxy
//    inbounds (incl. legacy tproxy-in-de/lv/kz) and any previous xm-probe.
function is_managed_in(o) {
	return o.protocol == 'dokodemo-door' && o.streamSettings &&
	       o.streamSettings.sockopt && o.streamSettings.sockopt.tproxy == 'tproxy';
}

let new_in = [], managed_tags = {}, ins = cfg.inbounds ?? [];
for (let i = 0; i < length(ins); i++) {
	if (is_managed_in(ins[i]) || ins[i].tag == 'xm-probe') managed_tags[ins[i].tag] = 1;
	else push(new_in, ins[i]);
}
managed_tags['tproxy-in'] = 1;

push(new_in, {
	tag: 'tproxy-in', protocol: 'dokodemo-door', listen: '0.0.0.0', port: fw.tproxy_port,
	settings: { network: 'tcp', followRedirect: true },
	sniffing: { enabled: true, destOverride: [ 'http', 'tls' ], routeOnly: true },
	streamSettings: { sockopt: { tproxy: 'tproxy' } }
});
// Loopback-only probe: the xray-fw watchdog curls through it to prove the
// data plane (dispatcher + freedom outbound) end-to-end, not just a bound port.
push(new_in, {
	tag: 'xm-probe', protocol: 'dokodemo-door', listen: '127.0.0.1', port: fw.probe_port,
	settings: { address: 'www.gstatic.com', port: 80, network: 'tcp' }
});
cfg.inbounds = new_in;

// -- outbounds: sockopt.mark on everything that dials out (loop prevention —
//    the nft chain skips packets carrying fw.mark_out); ensure `direct` exists.
let has_direct = false, obs = cfg.outbounds ?? [];
for (let i = 0; i < length(obs); i++) {
	let o = obs[i];
	if (o.tag == 'direct') has_direct = true;
	if (o.protocol == 'blackhole') continue;
	if (!o.streamSettings) o.streamSettings = {};
	if (!o.streamSettings.sockopt) o.streamSettings.sockopt = {};
	o.streamSettings.sockopt.mark = fw.mark_out;
}
if (!has_direct) {
	push(obs, { tag: 'direct', protocol: 'freedom',
	            streamSettings: { sockopt: { mark: fw.mark_out } } });
	push(warnings, "no 'direct' outbound existed — appended one");
}
cfg.outbounds = obs;

// -- rules: keep everything that is neither ours (xm:) nor a legacy simple
//    inbound->exit rule for a swept tproxy inbound (api/socks-dns rules stay).
function is_legacy_managed_rule(r) {
	if (r.type != 'field' || !r.inboundTag || length(r.inboundTag) != 1) return false;
	if (!managed_tags[r.inboundTag[0]]) return false;
	if (r.domain || r.ip || r.port || r.protocol || r.source || r.user || r.network) return false;
	return true;
}

let kept = [], rules = (cfg.routing && cfg.routing.rules) ? cfg.routing.rules : [];
for (let i = 0; i < length(rules); i++) {
	let r = rules[i];
	if (r.ruleTag != null && substr(r.ruleTag, 0, 3) == 'xm:') continue;
	if (is_legacy_managed_rule(r)) continue;
	push(kept, r);
}

let known = exit_map();

// Dangling exits (e.g. a subscription refresh dropped the tag) degrade to the
// registry exit — degraded-but-proxied beats silently-direct on this network.
function resolve_exit(tag, what) {
	if (known[tag]) return tag;
	let fb = known[globals.registry_exit] ? globals.registry_exit : 'direct';
	push(warnings, sprintf("%s: exit '%s' missing — using '%s'", what, tag, fb));
	return fb;
}

let needs_geosite = false, needs_geoip = false;
function scan_geo(doms, ips) {
	for (let d in doms) if (substr(d, 0, 8) == 'geosite:') needs_geosite = true;
	for (let x in ips) if (substr(x, 0, 6) == 'geoip:') needs_geoip = true;
}

function mk_rule(tag, exit_tag, fields) {
	let r = { type: 'field', inboundTag: [ 'tproxy-in' ], ruleTag: tag };
	for (let k in keys(fields)) if (length(fields[k])) r[k] = fields[k];
	if (known[exit_tag] == 'balancer') r.balancerTag = exit_tag;
	else r.outboundTag = exit_tag;
	return r;
}

let managed = [];

// probe first: must always exit direct
push(managed, { type: 'field', inboundTag: [ 'xm-probe' ], ruleTag: 'xm:probe', outboundTag: 'direct' });

// per-list entries + device sources bypassing each list
let entries = {};
for (let l in lists) entries[l.name] = parse_entries(l.name);

function bypass_sources(list_name) {
	let src = [];
	for (let d in devices)
		if (d.enabled && !d.bypass_all && length(d.ip) && (list_name in d.bypass))
			push(src, d.ip);
	return src;
}

for (let l in lists) {
	if (!l.enabled) continue;
	let src = bypass_sources(l.name), e = entries[l.name];
	if (!length(src)) continue;
	if (length(e.domains))
		push(managed, mk_rule('xm:devbypass:' + l.name + ':domain', 'direct', { source: src, domain: e.domains }));
	if (length(e.ips))
		push(managed, mk_rule('xm:devbypass:' + l.name + ':ip', 'direct', { source: src, ip: e.ips }));
}

if (globals.registry_enabled) {
	let src = bypass_sources('registry');
	if (length(src)) {
		if (length(globals.registry_geosite))
			push(managed, mk_rule('xm:devbypass:registry:domain', 'direct',
				{ source: src, domain: [ 'geosite:' + globals.registry_geosite ] }));
		if (length(globals.registry_geoip))
			push(managed, mk_rule('xm:devbypass:registry:ip', 'direct',
				{ source: src, ip: [ 'geoip:' + globals.registry_geoip ] }));
	}
}

for (let l in lists) {
	if (!l.enabled) continue;
	let e = entries[l.name];
	scan_geo(e.domains, e.ips);
	let ex = resolve_exit(l.exit, "list '" + l.name + "'");
	if (length(e.domains))
		push(managed, mk_rule('xm:list:' + l.name + ':domain', ex, { domain: e.domains }));
	if (length(e.ips))
		push(managed, mk_rule('xm:list:' + l.name + ':ip', ex, { ip: e.ips }));
}

for (let g in georules) {
	if (!g.enabled) continue;
	scan_geo(g.domain, g.ip);
	if (!length(g.domain) && !length(g.ip) && !length(g.source)) {
		push(warnings, sprintf("georule '%s': no matchers — skipped", g.name));
		continue;
	}
	let r = mk_rule('xm:georule:' + g.name, resolve_exit(g.exit, "georule '" + g.name + "'"),
		{ domain: g.domain, ip: g.ip, source: g.source });
	if (length(g.network)) r.network = g.network;
	push(managed, r);
}

if (globals.registry_enabled) {
	let ex = resolve_exit(globals.registry_exit, 'registry');
	if (length(globals.registry_geosite)) {
		push(managed, mk_rule('xm:registry:domain', ex, { domain: [ 'geosite:' + globals.registry_geosite ] }));
		needs_geosite = true;
	}
	if (length(globals.registry_geoip)) {
		push(managed, mk_rule('xm:registry:ip', ex, { ip: [ 'geoip:' + globals.registry_geoip ] }));
		needs_geoip = true;
	}
}

push(managed, mk_rule('xm:default', resolve_exit(globals.default_exit, 'default'), {}));

// geo references require the .dat files (xray -test would fail later and the
// error is clearer here).
let gp = geodata_paths();
if (needs_geosite && stat(gp.geosite) == null)
	die('geosite.dat missing at ' + gp.geosite + ' — run a Geodata update first');
if (needs_geoip && stat(gp.geoip) == null)
	die('geoip.dat missing at ' + gp.geoip + ' — run a Geodata update first');

if (!cfg.routing) cfg.routing = {};
for (let r in managed) push(kept, r);
cfg.routing.rules = kept;

writefile(out_path, sprintf('%.2J', cfg));
printf('%J\n', { ok: true, warnings: warnings });

}
else {
	die('usage: genrules.uc get|set <config.json> [out-path]');
}
