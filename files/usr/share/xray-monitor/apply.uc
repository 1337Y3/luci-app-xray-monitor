#!/usr/bin/ucode
// Splice grouped subscription outbounds into config.json with // comment headers,
// preserving everything else. Non-proxy outbounds (direct/freedom) and proxy
// outbounds NOT tagged <prefix>/<prefix>-* (added by hand) go in a "local" block.
// argv: <config.json> <staged-groups.json> [out-path] [prefix ...]
// staged-groups.json = { "groups": [ { "label": "<prefix>", "outbounds": [ {...} ] } ] }
// Prefixes mark the managed exits (all configured subscriptions, enabled or not);
// without prefixes every proxy outbound is treated as managed (legacy behavior).
// The outbounds section is laid out by render.uc (shared with routing/balancers).
'use strict';
import { readfile } from 'fs';
import { emit, owner_prefix } from 'render';

let cfg = json(readfile(ARGV[0]));
let staged = json(readfile(ARGV[1]));
let out_path = ARGV[2];
let prefixes = [];
for (let i = 3; i < length(ARGV); i++) push(prefixes, ARGV[i]);
let groups = staged.groups ?? [];

function is_managed(tag) {
	if (!tag) return false;
	if (!length(prefixes)) return true;
	return owner_prefix(tag, prefixes) != null;
}

let proxy_protos = [ 'vless', 'vmess', 'trojan', 'shadowsocks' ];
let kept = [];
let old = cfg.outbounds ?? [];
for (let i = 0; i < length(old); i++)
	if (!(old[i].protocol in proxy_protos) || !is_managed(old[i].tag)) push(kept, old[i]);

// The final outbounds are the staged groups followed by the kept locals. A tag
// carried twice (a legacy staged state from when overlapping prefixes were
// still allowed, or hand-edited) would make xray -test fail with a bare
// "existing tag found" - reject it here, naming the tag.
let seen = {}, dup = null;
for (let g = 0; g < length(groups) && dup == null; g++) {
	let go = groups[g].outbounds ?? [];
	for (let i = 0; i < length(go); i++) {
		let t = go[i].tag;
		if (t && exists(seen, t)) { dup = t; break; }
		seen[t] = 1;
	}
}
for (let i = 0; i < length(kept) && dup == null; i++) {
	let t = kept[i].tag;
	if (t && exists(seen, t)) { dup = t; break; }
	seen[t] = 1;
}
if (dup != null) {
	warn(sprintf('duplicate outbound tag "%s" (same tag in two staged groups, or overlapping subscription prefixes?) - not applied\n', dup));
	exit(1);
}

emit(cfg, groups, kept, out_path);
