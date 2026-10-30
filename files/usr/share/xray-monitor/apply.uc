#!/usr/bin/ucode
// Splice grouped subscription outbounds into config.json with // comment headers,
// preserving everything else. Non-proxy outbounds (direct/freedom) and proxy
// outbounds NOT tagged <prefix>/<prefix>-* (added by hand) go in a "local" block.
// argv: <config.json> <staged-groups.json> [out-path] [prefix ...]
// staged-groups.json = { "groups": [ { "label": "<prefix>", "outbounds": [ {...} ] } ] }
// Prefixes mark the managed exits (all configured subscriptions, enabled or not);
// without prefixes every proxy outbound is treated as managed (legacy behavior).
'use strict';
import { readfile, writefile } from 'fs';

let cfg = json(readfile(ARGV[0]));
let staged = json(readfile(ARGV[1]));
let out_path = ARGV[2];
let prefixes = [];
for (let i = 3; i < length(ARGV); i++) push(prefixes, ARGV[i]);
let groups = staged.groups ?? [];

function is_managed(tag) {
	if (!tag) return false;
	if (!length(prefixes)) return true;
	for (let i = 0; i < length(prefixes); i++)
		if (tag == prefixes[i] || substr(tag, 0, length(prefixes[i]) + 1) == prefixes[i] + '-') return true;
	return false;
}

let proxy_protos = [ 'vless', 'vmess', 'trojan', 'shadowsocks' ];
let kept = [];
let old = cfg.outbounds ?? [];
for (let i = 0; i < length(old); i++)
	if (!(old[i].protocol in proxy_protos) || !is_managed(old[i].tag)) push(kept, old[i]);

function indent(s, pad) {
	let lines = split(s, "\n"), out = [];
	for (let i = 0; i < length(lines); i++) push(out, pad + lines[i]);
	return join("\n", out);
}

let parts = [];
for (let g = 0; g < length(groups); g++) {
	let grp = groups[g], obs = grp.outbounds ?? [];
	if (!length(obs)) continue;
	push(parts, "    // === subscription: " + ((grp.label && length(grp.label)) ? grp.label : "(default)") + " ===");
	for (let i = 0; i < length(obs); i++)
		push(parts, indent(sprintf('%.2J', obs[i]), "    "));
}
if (length(kept)) {
	push(parts, "    // === local ===");
	for (let i = 0; i < length(kept); i++)
		push(parts, indent(sprintf('%.2J', kept[i]), "    "));
}
let ob_text = "[\n" + join(",\n", parts) + "\n  ]";

cfg.outbounds = "__OB__";
let full = sprintf('%.2J', cfg);
full = replace(full, '"outbounds": "__OB__"', '"outbounds": ' + ob_text);

if (out_path) { writefile(out_path, full); printf('OK\n'); }
else printf('%s\n', full);
