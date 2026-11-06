#!/usr/bin/ucode
// Materialize the currently installed outbounds of ONE subscription as a staged
// group. `xray-sub fetch` appends such groups for subscriptions whose refetch
// failed, so the diff stays clean and `apply` (incl. auto-apply) does not read
// a temporary network/panel failure as "remove all its exits" - the router
// keeps serving the last known-good servers of that subscription.
// argv: <config.json> <prefix> [other-prefix ...]   ->  [ { outbound }, ... ]
// The remaining prefixes (all configured subscriptions) decide OWNERSHIP: an
// outbound belongs to <prefix> only if it is the longest matching prefix
// (render.uc owner_prefix). With nested prefixes ("proxy" + "proxy-work") the
// snapshot of a failed "proxy" fetch must keep "proxy-de" but must NOT capture
// "proxy-work-fi" - the other subscription's own staged group already carries
// that exit, and a duplicate tag would make xray -test reject the config.
'use strict';
import { readfile } from 'fs';
import { owner_prefix } from 'render';

let cfg = json(readfile(ARGV[0]));
let pfx = ARGV[1] ?? '';
let prefixes = [ pfx ];
for (let i = 2; i < length(ARGV); i++) push(prefixes, ARGV[i]);

let proxy_protos = [ 'vless', 'vmess', 'trojan', 'shadowsocks' ];
let out = [], obs = cfg.outbounds ?? [];
for (let i = 0; i < length(obs); i++)
	if (obs[i].tag && obs[i].protocol in proxy_protos && owner_prefix(obs[i].tag, prefixes) == pfx)
		push(out, obs[i]);

printf('%J\n', out);
