#!/usr/bin/ucode
// Splice grouped subscription outbounds into config.json with // comment headers,
// preserving everything else. Non-proxy outbounds (direct/freedom) go in a "local" block.
// argv: <config.json> <staged-groups.json> [out-path]
// staged-groups.json = { "groups": [ { "label": "<prefix>", "outbounds": [ {...} ] } ] }
'use strict';
import { readfile, writefile } from 'fs';
import { cursor } from 'uci';

let cfg = json(readfile(ARGV[0]));
let staged = json(readfile(ARGV[1]));
let out_path = ARGV[2];
let groups = staged.groups ?? [];

// Managed routing (xray-rules) needs sockopt.mark on every outbound so the
// nft tproxy chain can skip xray's own egress. Injecting here is the single
// choke point that keeps nightly-spliced subscription outbounds marked too.
// Gated on rules.managed so a not-yet-migrated install stays byte-identical.
let uctx = cursor();
let managed = uctx.get('xray-monitor', 'rules', 'managed') == '1';
let mark = int(uctx.get('xray-monitor', 'fw', 'mark_out') || 256);
function set_mark(o) {
	if (!managed || o.protocol == 'blackhole') return o;
	if (!o.streamSettings) o.streamSettings = {};
	if (!o.streamSettings.sockopt) o.streamSettings.sockopt = {};
	o.streamSettings.sockopt.mark = mark;
	return o;
}

let proxy_protos = [ 'vless', 'vmess', 'trojan', 'shadowsocks' ];
let kept = [];
let old = cfg.outbounds ?? [];
for (let i = 0; i < length(old); i++)
	if (!(old[i].protocol in proxy_protos)) push(kept, set_mark(old[i]));

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
		push(parts, indent(sprintf('%.2J', set_mark(obs[i])), "    "));
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
