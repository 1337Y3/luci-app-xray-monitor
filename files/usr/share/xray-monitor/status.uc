#!/usr/bin/ucode
// Compose the sub_get response: subscriptions + global settings (from UCI) +
// fetch state + the INSTALLED proxy outbounds (from the live config) + pending diff.
//   status.uc <last_fetch> <status> <pending> <config.json> <diff.json>
'use strict';
import { readfile } from 'fs';
import { cursor } from 'uci';

let lf = ARGV[0], st = ARGV[1], pending = ARGV[2], cfg_path = ARGV[3], diff_path = ARGV[4];

function load(p, dflt) { let s = p ? readfile(p) : null; return s ? json(s) : dflt; }
function mask(u) { if (!u || !length(u)) return ''; let p = split(u, '/'); return (length(p) >= 3) ? (p[0] + '//' + p[2] + '/****') : '****'; }

let uci = cursor();
let g = function(o) { return uci.get('xray-monitor', 'sub', o); };

let subs = [];
uci.foreach('xray-monitor', 'subscription', function(s) {
	push(subs, {
		id: s['.name'],
		prefix: s.prefix ?? 'proxy',
		url_masked: mask(s.url),
		has_url: (s.url && length(s.url)) ? true : false,
		enabled: (s.enabled == '0') ? false : true
	});
});

let cfg = load(cfg_path, {});
let diff = load(diff_path, { added: [], removed: [], changed: [], total: 0 });
let proxy_protos = [ 'vless', 'vmess', 'trojan', 'shadowsocks' ];
let servers = [], obs = cfg.outbounds ?? [];
for (let i = 0; i < length(obs); i++) {
	let o = obs[i];
	if (!(o.protocol in proxy_protos)) continue;
	let s = o.settings ?? {}, v = (s.vnext && s.vnext[0]) ? s.vnext[0] : {};
	let ss = o.streamSettings ?? {}, rs = ss.realitySettings ?? {}, xs = ss.xhttpSettings ?? {};
	push(servers, { tag: o.tag, address: v.address, port: v.port, network: ss.network, mode: xs.mode, sni: rs.serverName });
}

printf('%J\n', {
	subscriptions: subs,
	cron: (g('cron') == '0') ? false : true,
	cron_schedule: g('cron_schedule') ?? '0 * * * *',
	auto_apply: (g('auto_apply') == '1') ? true : false,
	user_agent: g('user_agent') ?? '',
	last_fetch: int(lf) ?? 0,
	status: (st && length(st)) ? st : 'never',
	pending: (pending == '1') ? true : false,
	diff: diff,
	servers: servers
});
