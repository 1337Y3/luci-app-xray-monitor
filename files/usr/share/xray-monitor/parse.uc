#!/usr/bin/ucode
// One Remnawave subscription -> xray proxy outbounds with stable, prefixed tags.
// argv: <sub.json> <tagmap.json> <overrides.json> <prefix>
// tag = <prefix>-<base>; tagmap stores remark->base. A NEW base is sanitized to
// [a-z0-9_-] (emoji/spaces/punctuation stripped, empty -> "srv") and suffixed
// -2, -3, ... on collision. Bases already in tagmap are NEVER recomputed, so
// tags stay stable across fetches (routing/balancers keep working); tags are
// additionally de-duplicated within one run.
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
// Byte-wise filter to [a-z0-9_-]: UTF-8 multibyte sequences (emoji, Cyrillic),
// spaces and punctuation are all >= 0x80 or outside the class and drop out.
function sanitize_base(s) {
	let chars = [];
	s = lc(s);
	for (let i = 0; i < length(s); i++) {
		let c = substr(s, i, 1);
		if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')
			push(chars, c);
	}
	let b = join('', chars);
	return length(b) ? b : 'srv';
}
function deepmerge(base, ovr) {
	if (type(base) != 'object' || type(ovr) != 'object') return ovr;
	for (let k in ovr)
		base[k] = (type(base[k]) == 'object' && type(ovr[k]) == 'object') ? deepmerge(base[k], ovr[k]) : ovr[k];
	return base;
}

let proxy_protos = [ 'vless', 'vmess', 'trojan', 'shadowsocks' ];
let out = [], changed = false;
// every base known to tagmap or freshly assigned here (collision domain), and
// every full tag emitted in this run (final uniqueness guarantee)
let bases = {}, used = {};
for (let k in tagmap) bases[tagmap[k]] = 1;

for (let i = 0; i < length(sub); i++) {
	let el = sub[i], r = el.remarks, obs = el.outbounds;
	if (!r || type(obs) != 'array') continue;
	let p = null;
	for (let j = 0; j < length(obs); j++) if (obs[j].tag == 'proxy') { p = obs[j]; break; }
	if (!p) for (let j = 0; j < length(obs); j++) if (obs[j].protocol in proxy_protos) { p = obs[j]; break; }
	if (!p) continue;

	if (!exists(tagmap, r)) {
		// sanitize, then avoid any base already taken: suffix -2, -3, ...
		let b = sanitize_base(derive_base(r)), cand = b, n = 2;
		while (exists(bases, cand)) { cand = b + '-' + n; n++; }
		tagmap[r] = cand; bases[cand] = 1; changed = true;
	}
	let t = prefix + '-' + tagmap[r], cand2 = t, n2 = 2;
	while (exists(used, cand2)) { cand2 = t + '-' + n2; n2++; }
	used[cand2] = 1;
	p.tag = cand2;
	if (overrides[p.tag]) p = deepmerge(p, overrides[p.tag]);
	push(out, p);
}

if (changed && tagmap_path) writefile(tagmap_path, sprintf('%J', tagmap));
printf('%J\n', out);
