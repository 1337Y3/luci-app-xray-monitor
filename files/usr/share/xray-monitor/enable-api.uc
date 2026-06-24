#!/usr/bin/ucode
// Idempotently add the Xray Stats API (stats/api/policy + api inbound + api rule)
// to an existing config. Writes the (possibly unchanged) result to out-path and
// prints "changed" or "unchanged".
//   enable-api.uc <config.json> <out-path> [port]
'use strict';
import { readfile, writefile } from 'fs';

let cfg_path = ARGV[0], out_path = ARGV[1];
let port = ARGV[2] ? int(ARGV[2]) : 10085;

let cfg = json(readfile(cfg_path));
if (type(cfg) != 'object') { warn('not a JSON object\n'); exit(1); }
let before = sprintf('%J', cfg);

// stats {}
if (type(cfg.stats) != 'object') cfg.stats = {};

// api { tag, services:[...StatsService] }
if (type(cfg.api) != 'object') cfg.api = { tag: 'api', services: [ 'StatsService' ] };
else {
	if (!cfg.api.tag) cfg.api.tag = 'api';
	if (type(cfg.api.services) != 'array') cfg.api.services = [ 'StatsService' ];
	else {
		let has = false;
		for (let i = 0; i < length(cfg.api.services); i++) if (cfg.api.services[i] == 'StatsService') has = true;
		if (!has) push(cfg.api.services, 'StatsService');
	}
}
let apitag = cfg.api.tag;

// policy.system stats flags
if (type(cfg.policy) != 'object') cfg.policy = {};
if (type(cfg.policy.system) != 'object') cfg.policy.system = {};
cfg.policy.system.statsInboundUplink = true;
cfg.policy.system.statsInboundDownlink = true;
cfg.policy.system.statsOutboundUplink = true;
cfg.policy.system.statsOutboundDownlink = true;

// api dokodemo inbound on 127.0.0.1:port (if no inbound already carries the api tag)
if (type(cfg.inbounds) != 'array') cfg.inbounds = [];
let has_in = false;
for (let i = 0; i < length(cfg.inbounds); i++) if (cfg.inbounds[i].tag == apitag) has_in = true;
// Insert the api inbound FIRST so it binds ahead of the tproxy inbounds. On
// boxes that double-load config (e.g. `-confdir` + `-config`) a trailing
// inbound can fail to come up while earlier ones bind, silently killing the API.
if (!has_in)
	unshift(cfg.inbounds, {
		tag: apitag, protocol: 'dokodemo-door', listen: '127.0.0.1',
		port: port, settings: { address: '127.0.0.1' }
	});

// routing rule inboundTag[apitag] -> outboundTag apitag (prepend) if absent
if (type(cfg.routing) != 'object') cfg.routing = {};
if (type(cfg.routing.rules) != 'array') cfg.routing.rules = [];
let has_rule = false;
for (let i = 0; i < length(cfg.routing.rules); i++) {
	let r = cfg.routing.rules[i];
	if (r.inboundTag)
		for (let j = 0; j < length(r.inboundTag); j++) if (r.inboundTag[j] == apitag) has_rule = true;
}
if (!has_rule) {
	let nr = [ { type: 'field', inboundTag: [ apitag ], outboundTag: apitag } ];
	for (let i = 0; i < length(cfg.routing.rules); i++) push(nr, cfg.routing.rules[i]);
	cfg.routing.rules = nr;
}

writefile(out_path, sprintf('%.2J', cfg));
print((before != sprintf('%J', cfg)) ? 'changed\n' : 'unchanged\n');
