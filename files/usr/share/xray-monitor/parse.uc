#!/usr/bin/ucode
// One Remnawave subscription -> xray proxy outbounds with stable, prefixed tags.
// argv: <sub.json> <tagmap.json> <overrides.json> <prefix>
// tag = <prefix>-<cc>[-n]   (prefix defaults to "proxy"); tagmap stores remark->base.
'use strict';
import { readfile, writefile } from 'fs';

let sub_path = ARGV[0], tagmap_path = ARGV[1], ovr_path = ARGV[2];
let prefix = (ARGV[3] && length(ARGV[3])) ? ARGV[3] : 'proxy';

function load(p, dflt) { let s = p ? readfile(p) : null; return s ? json(s) : dflt; }

let sub = load(sub_path, []);
let tagmap = load(tagmap_path, {});       // remark -> base (e.g. "de-1")
let overrides = load(ovr_path, {});       // <fulltag> -> partial outbound to deep-merge

// count servers per country code (prefix before first '-') for the base heuristic
let ccount = {};
for (let i = 0; i < length(sub); i++) {
	let r = sub[i].remarks;
	if (!r) continue;
	let cc = lc(split(r, '-')[0]);
	ccount[cc] = (ccount[cc] ?? 0) + 1;
}
function derive_base(remark) {
	let parts = split(remark, '-'), cc = lc(parts[0]), n = parts[1] ?? '1';
	return (ccount[cc] > 1) ? (cc + '-' + n) : cc;
}
function deepmerge(base, ovr) {
	if (type(base) != 'object' || type(ovr) != 'object') return ovr;
	for (let k in ovr)
		base[k] = (type(base[k]) == 'object' && type(ovr[k]) == 'object') ? deepmerge(base[k], ovr[k]) : ovr[k];
	return base;
}

let proxy_protos = [ 'vless', 'vmess', 'trojan', 'shadowsocks' ];
let out = [], changed = false;
for (let i = 0; i < length(sub); i++) {
	let el = sub[i], r = el.remarks, obs = el.outbounds;
	if (!r || type(obs) != 'array') continue;
	let p = null;
	for (let j = 0; j < length(obs); j++) if (obs[j].tag == 'proxy') { p = obs[j]; break; }
	if (!p) for (let j = 0; j < length(obs); j++) if (obs[j].protocol in proxy_protos) { p = obs[j]; break; }
	if (!p) continue;

	if (!exists(tagmap, r)) { tagmap[r] = derive_base(r); changed = true; }
	p.tag = prefix + '-' + tagmap[r];
	if (overrides[p.tag]) p = deepmerge(p, overrides[p.tag]);
	push(out, p);
}

if (changed && tagmap_path) writefile(tagmap_path, sprintf('%J', tagmap));
printf('%J\n', out);
