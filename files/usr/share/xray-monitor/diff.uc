#!/usr/bin/ucode
// Diff staged (grouped) proxy outbounds against the proxies currently in config.json.
// argv: <staged-groups.json> <config.json> [prefix ...] [-- dot.path ...]
//   ->  { added, removed, changed, total }
// With prefixes, only outbounds tagged <prefix> or <prefix>-* (the subscriptions'
// own exits) are managed; proxy outbounds added by hand are left alone. Without
// prefixes every proxy outbound is managed (legacy behavior).
// The dot-paths after `--` are pruned from both sides before comparing (default:
// streamSettings.realitySettings.spiderX, which the panel randomizes per fetch).
'use strict';
import { readfile } from 'fs';
import { canonsig } from 'jsondiff';

let staged = json(readfile(ARGV[0]));
let cfg = json(readfile(ARGV[1]));
let prefixes = [], ignores = [], into_ignores = false;
for (let i = 2; i < length(ARGV); i++) {
	if (ARGV[i] == '--') { into_ignores = true; continue; }
	if (into_ignores) push(ignores, ARGV[i]); else push(prefixes, ARGV[i]);
}
if (!length(ignores)) push(ignores, 'streamSettings.realitySettings.spiderX');
let proxy_protos = [ 'vless', 'vmess', 'trojan', 'shadowsocks' ];

function is_managed(tag) {
	if (!tag) return false;
	if (!length(prefixes)) return true;
	for (let i = 0; i < length(prefixes); i++)
		if (tag == prefixes[i] || substr(tag, 0, length(prefixes[i]) + 1) == prefixes[i] + '-') return true;
	return false;
}

// canonsig() lives in jsondiff.uc now (shared with the paths_diff module);
// everything below is unchanged.

// Signature covers the WHOLE outbound body (minus the tag, which is the map
// key): endpoint, transport, credentials and everything else - tlsSettings,
// wsSettings path/host, grpc serviceName, xhttpSettings incl. its "extra"
// object, sockopt, mux, ... The old hand-picked field list (which declared
// xhttpSettings but never used it) missed those, so panel changes that only
// touched e.g. xhttpSettings.extra read as "no change" and never raised
// `pending`, silently skipping auto-apply.
// Delete one dot-path (e.g. "streamSettings.realitySettings.spiderX") from an
// outbound copy; missing segments are not an error.
function prune(o, path) {
	let segs = split(path, '.');
	let cur = o;
	for (let i = 0; i < length(segs) - 1; i++) {
		if (type(cur) != 'object' || !exists(cur, segs[i])) return;
		cur = cur[segs[i]];
	}
	if (type(cur) == 'object') delete cur[segs[length(segs) - 1]];
}

function body_of(o) {
	let c = {};
	for (let k in o) if (k != 'tag') c[k] = o[k];
	for (let i = 0; i < length(ignores); i++) prune(c, ignores[i]);
	return canonsig(c);
}

let cur = {}, obs = cfg.outbounds ?? [];
for (let i = 0; i < length(obs); i++)
	if (obs[i].protocol in proxy_protos && is_managed(obs[i].tag)) cur[obs[i].tag] = body_of(obs[i]);

let neu = {}, groups = staged.groups ?? [];
for (let g = 0; g < length(groups); g++) {
	let go = groups[g].outbounds ?? [];
	for (let i = 0; i < length(go); i++) neu[go[i].tag] = body_of(go[i]);
}

let added = [], removed = [], changed = [];
for (let t in neu) {
	if (!exists(cur, t)) push(added, t);
	else if (cur[t] != neu[t]) push(changed, t);
}
for (let t in cur) if (!exists(neu, t)) push(removed, t);

printf('%J\n', { added, removed, changed, total: length(added) + length(removed) + length(changed) });
