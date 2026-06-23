#!/usr/bin/ucode
// Compose the sub_get response: state + the INSTALLED proxy outbounds (from the
// live config) + the pending diff from the last fetch.
//   status.uc <url> <last_fetch> <status> <pending> <config.json> <diff.json>
//             <cron> <cron_schedule> <auto_apply> <user_agent>
'use strict';
import { readfile } from 'fs';

let url = ARGV[0], lf = ARGV[1], st = ARGV[2], pending = ARGV[3];
let cfg_path = ARGV[4], diff_path = ARGV[5];
let cron = ARGV[6], cron_schedule = ARGV[7], auto_apply = ARGV[8], user_agent = ARGV[9];

function load(p, dflt) {
	let s = p ? readfile(p) : null;
	return s ? json(s) : dflt;
}

function mask(u) {
	if (!u || !length(u)) return '';
	let parts = split(u, '/');
	return (length(parts) >= 3) ? (parts[0] + '//' + parts[2] + '/****') : '****';
}

let cfg = load(cfg_path, {});
let diff = load(diff_path, { added: [], removed: [], changed: [], total: 0 });
let proxy_protos = [ 'vless', 'vmess', 'trojan', 'shadowsocks' ];

let servers = [];
let obs = cfg.outbounds ?? [];
for (let i = 0; i < length(obs); i++) {
	let o = obs[i];
	if (!(o.protocol in proxy_protos)) continue;
	let s = o.settings ?? {};
	let v = (s.vnext && s.vnext[0]) ? s.vnext[0] : ((s.servers && s.servers[0]) ? s.servers[0] : {});
	let ss = o.streamSettings ?? {};
	let rs = ss.realitySettings ?? {};
	let xs = ss.xhttpSettings ?? {};
	push(servers, {
		tag: o.tag, address: v.address, port: v.port,
		network: ss.network, mode: xs.mode, sni: rs.serverName
	});
}

printf('%J\n', {
	has_url: (url && length(url) > 0) ? true : false,
	url_masked: mask(url),
	last_fetch: int(lf) ?? 0,
	status: st ?? 'never',
	pending: (pending == '1') ? true : false,
	cron: (cron == '0') ? false : true,
	cron_schedule: cron_schedule ?? '0 * * * *',
	auto_apply: (auto_apply == '1') ? true : false,
	user_agent: user_agent ?? '',
	diff: diff,
	servers: servers
});
