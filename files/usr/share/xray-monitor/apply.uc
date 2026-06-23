#!/usr/bin/ucode
// Splice staged proxy outbounds into config.json, preserving everything else.
// argv: <config.json> <staged-outbounds.json> [out-path]   (no out-path => stdout)
'use strict';
import { readfile, writefile } from 'fs';

let cfg_path = ARGV[0], staged_path = ARGV[1], out_path = ARGV[2];

let cfg = json(readfile(cfg_path));
let staged = json(readfile(staged_path));

let proxy_protos = ['vless', 'vmess', 'trojan', 'shadowsocks'];

// keep all non-proxy outbounds (freedom/blackhole/dns/...) in original order
let kept = [];
let old = cfg.outbounds ?? [];
for (let i = 0; i < length(old); i++)
	if (!(old[i].protocol in proxy_protos))
		push(kept, old[i]);

// new outbounds = staged proxies, then kept ones (direct/freedom stay last)
let neu = [];
for (let i = 0; i < length(staged); i++) push(neu, staged[i]);
for (let i = 0; i < length(kept); i++) push(neu, kept[i]);
cfg.outbounds = neu;

let s = sprintf('%.2J', cfg);
if (out_path) { writefile(out_path, s); printf('OK %d outbounds\n', length(neu)); }
else printf('%s\n', s);
