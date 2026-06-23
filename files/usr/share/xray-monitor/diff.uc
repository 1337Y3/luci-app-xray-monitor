#!/usr/bin/ucode
// Diff staged proxy outbounds against the proxies currently in config.json.
// argv: <staged.json> <config.json>  ->  { added, removed, changed, total }
'use strict';
import { readfile } from 'fs';

let staged = json(readfile(ARGV[0]));
let cfg = json(readfile(ARGV[1]));
let proxy_protos = ['vless', 'vmess', 'trojan', 'shadowsocks'];

function key_of(o) {
	let s = o.settings ?? {};
	let v = (s.vnext && s.vnext[0]) ? s.vnext[0] : ((s.servers && s.servers[0]) ? s.servers[0] : {});
	let ss = o.streamSettings ?? {};
	let rs = ss.realitySettings ?? {};
	let xs = ss.xhttpSettings ?? {};
	return sprintf('%s|%s|%s|%s|%s', v.address, v.port, ss.network, rs.serverName, xs.mode);
}

let cur = {};
let obs = cfg.outbounds ?? [];
for (let i = 0; i < length(obs); i++)
	if (obs[i].protocol in proxy_protos) cur[obs[i].tag] = key_of(obs[i]);

let neu = {};
for (let i = 0; i < length(staged); i++) neu[staged[i].tag] = key_of(staged[i]);

let added = [], removed = [], changed = [];
for (let t in neu) {
	if (!exists(cur, t)) push(added, t);
	else if (cur[t] != neu[t]) push(changed, t);
}
for (let t in cur)
	if (!exists(neu, t)) push(removed, t);

printf('%J\n', { added, removed, changed, total: length(added) + length(removed) + length(changed) });
