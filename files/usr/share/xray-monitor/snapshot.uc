#!/usr/bin/ucode
// Materialize the currently installed outbounds of ONE subscription as a staged
// group. `xray-sub fetch` appends such groups for subscriptions whose refetch
// failed, so the diff stays clean and `apply` (incl. auto-apply) does not read
// a temporary network/panel failure as "remove all its exits" - the router
// keeps serving the last known-good servers of that subscription.
// argv: <config.json> <prefix>   ->  [ { outbound }, ... ]
'use strict';
import { readfile } from 'fs';

let cfg = json(readfile(ARGV[0]));
let pfx = ARGV[1] ?? '';

// Same managed-tag rule as apply.uc / diff.uc: the bare prefix and <prefix>-*
function managed(tag) {
	return tag == pfx || substr(tag, 0, length(pfx) + 1) == pfx + '-';
}

let proxy_protos = [ 'vless', 'vmess', 'trojan', 'shadowsocks' ];
let out = [], obs = cfg.outbounds ?? [];
for (let i = 0; i < length(obs); i++)
	if (obs[i].tag && managed(obs[i].tag) && obs[i].protocol in proxy_protos) push(out, obs[i]);

printf('%J\n', out);
