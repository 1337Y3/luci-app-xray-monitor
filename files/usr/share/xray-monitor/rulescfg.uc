#!/usr/bin/ucode
// Validate UI payloads and persist them as UCI state + per-list entry files.
// The counterpart reader is genrules.uc; this script never touches config.json.
//   rulescfg.uc lists    <payload.json>   [{name,exit,dns,enabled,order,entries}]
//   rulescfg.uc devices  <payload.json>   [{name,ip,bypass_all,bypass[],enabled}]
//   rulescfg.uc georules <payload.json>   [{name,enabled,order,domain[],ip[],source[],network,exit}]
//   rulescfg.uc globals  <payload.json>   {default_exit,registry_enabled,registry_exit,
//                                          registry_geosite,registry_geoip,tproxy_port}
// Replaces ALL sections of the type with the payload (the UI always sends the
// full set). Prints "ok" on success, die()s with a message on invalid input.
'use strict';
import { readfile, writefile, unlink, lsdir, mkdir, stat } from 'fs';
import { cursor } from 'uci';

const XM = 'xray-monitor';
const LISTDIR = '/etc/xray-monitor/lists';

let action = ARGV[0];
let payload = json(readfile(ARGV[1]));
let ctx = cursor();

function s(v, def) { return (v == null) ? (def ?? '') : '' + v; }
function b(v) { return (v == '1' || v == 1 || v === true) ? '1' : '0'; }
function arr(v) { return (type(v) == 'array') ? v : []; }

function valid_name(n)   { return match(n, /^[A-Za-z0-9_-]{1,32}$/) != null; }
function valid_ipv4(ip)  { return match(ip, /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/) != null; }
function valid_cidr4(ip) { return match(ip, /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(\/[0-9]{1,2})?$/) != null; }
function valid_port(p)   { p = int(p); return p >= 1 && p <= 65535; }

// dnsmasq server target: IPv4 with optional #port; comma-separated multi
function valid_dns(v) {
	if (!length(v)) return true;
	for (let part in split(v, ',')) {
		part = trim(part);
		if (match(part, /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(#[0-9]{1,5})?$/) == null)
			return false;
	}
	return true;
}

function wipe_sections(sec_type) {
	let names = [];
	ctx.foreach(XM, sec_type, function(sec) { push(names, sec['.name']); });
	for (let n in names) ctx.delete(XM, n);
}

if (type(payload) == null || payload == null)
	die('invalid or empty JSON payload');

if (action == 'lists') {
	if (type(payload) != 'array') die('payload must be an array');
	let seen = {};
	for (let l in payload) {
		if (!valid_name(s(l.name))) die("invalid list name: '" + s(l.name) + "'");
		if (seen[l.name]) die("duplicate list name: " + l.name);
		seen[l.name] = 1;
		if (!length(s(l.exit))) die("list '" + l.name + "': empty exit");
		if (!valid_dns(s(l.dns))) die("list '" + l.name + "': invalid DNS (use IPv4[#port][,IPv4[#port]...])");
	}
	mkdir('/etc/xray-monitor'); mkdir(LISTDIR);
	wipe_sections('list');
	for (let l in payload) {
		let sid = ctx.add(XM, 'list');
		ctx.set(XM, sid, 'name', s(l.name));
		ctx.set(XM, sid, 'exit', s(l.exit));
		ctx.set(XM, sid, 'dns', s(l.dns));
		ctx.set(XM, sid, 'enabled', b(l.enabled));
		ctx.set(XM, sid, 'order', s(int(l.order ?? 100)));
		if (l.entries != null) {
			let text = replace('' + l.entries, "\r\n", "\n");
			if (length(text) && substr(text, -1) != "\n") text += "\n";
			writefile(LISTDIR + '/' + l.name + '.lst', text);
		} else if (stat(LISTDIR + '/' + l.name + '.lst') == null) {
			writefile(LISTDIR + '/' + l.name + '.lst', '');
		}
	}
	// drop entry files of deleted lists
	for (let f in (lsdir(LISTDIR) ?? [])) {
		let m = match(f, /^(.+)\.lst$/);
		if (m && !seen[m[1]]) unlink(LISTDIR + '/' + f);
	}
	ctx.commit(XM);
	print("ok\n");
}
else if (action == 'devices') {
	if (type(payload) != 'array') die('payload must be an array');
	let seen = {};
	for (let d in payload) {
		if (!valid_ipv4(s(d.ip))) die("device '" + s(d.name) + "': invalid IPv4 '" + s(d.ip) + "'");
		if (seen[d.ip]) die("duplicate device IP: " + d.ip);
		seen[d.ip] = 1;
		for (let bn in arr(d.bypass))
			if (bn != 'registry' && !valid_name(s(bn))) die("device '" + s(d.name) + "': bad bypass entry '" + s(bn) + "'");
	}
	wipe_sections('device');
	for (let d in payload) {
		let sid = ctx.add(XM, 'device');
		ctx.set(XM, sid, 'name', s(d.name));
		ctx.set(XM, sid, 'ip', s(d.ip));
		ctx.set(XM, sid, 'bypass_all', b(d.bypass_all));
		ctx.set(XM, sid, 'enabled', b(d.enabled));
		if (length(arr(d.bypass))) ctx.set(XM, sid, 'bypass', arr(d.bypass));
	}
	ctx.commit(XM);
	print("ok\n");
}
else if (action == 'georules') {
	if (type(payload) != 'array') die('payload must be an array');
	let seen = {};
	for (let g in payload) {
		if (!valid_name(s(g.name))) die("invalid rule name: '" + s(g.name) + "'");
		if (seen[g.name]) die("duplicate rule name: " + g.name);
		seen[g.name] = 1;
		if (!length(s(g.exit))) die("rule '" + g.name + "': empty exit");
		if (!(s(g.network) in [ '', 'tcp' ])) die("rule '" + g.name + "': network must be '' or 'tcp'");
		for (let src in arr(g.source))
			if (!valid_cidr4(s(src))) die("rule '" + g.name + "': bad source '" + s(src) + "'");
	}
	wipe_sections('georule');
	for (let g in payload) {
		let sid = ctx.add(XM, 'georule');
		ctx.set(XM, sid, 'name', s(g.name));
		ctx.set(XM, sid, 'enabled', b(g.enabled));
		ctx.set(XM, sid, 'order', s(int(g.order ?? 100)));
		ctx.set(XM, sid, 'exit', s(g.exit));
		if (length(s(g.network))) ctx.set(XM, sid, 'network', s(g.network));
		if (length(arr(g.domain))) ctx.set(XM, sid, 'domain', arr(g.domain));
		if (length(arr(g.ip)))     ctx.set(XM, sid, 'ip', arr(g.ip));
		if (length(arr(g.source))) ctx.set(XM, sid, 'source', arr(g.source));
	}
	ctx.commit(XM);
	print("ok\n");
}
else if (action == 'globals') {
	if (type(payload) != 'object') die('payload must be an object');
	if (payload.tproxy_port != null && !valid_port(payload.tproxy_port))
		die('invalid tproxy_port');
	// sections are seeded by postinst; tolerate a wiped config anyway
	if (ctx.get(XM, 'rules') == null) ctx.set(XM, 'rules', 'routing');
	if (ctx.get(XM, 'fw') == null) ctx.set(XM, 'fw', 'fw');
	if (payload.default_exit != null && length(s(payload.default_exit)))
		ctx.set(XM, 'rules', 'default_exit', s(payload.default_exit));
	if (payload.registry_enabled != null)
		ctx.set(XM, 'rules', 'registry_enabled', b(payload.registry_enabled));
	if (payload.registry_exit != null && length(s(payload.registry_exit)))
		ctx.set(XM, 'rules', 'registry_exit', s(payload.registry_exit));
	if (payload.registry_geosite != null)
		ctx.set(XM, 'rules', 'registry_geosite', s(payload.registry_geosite));
	if (payload.registry_geoip != null)
		ctx.set(XM, 'rules', 'registry_geoip', s(payload.registry_geoip));
	if (payload.tproxy_port != null)
		ctx.set(XM, 'fw', 'tproxy_port', s(int(payload.tproxy_port)));
	ctx.commit(XM);
	print("ok\n");
}
else {
	die('usage: rulescfg.uc lists|devices|georules|globals <payload.json>');
}
