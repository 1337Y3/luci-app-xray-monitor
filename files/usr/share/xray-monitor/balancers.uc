#!/usr/bin/ucode
// Read/write routing.balancers (combine outbounds). Auto-maintains the
// observatory subjectSelector for leastPing/leastLoad members.
//   balancers.uc get <config.json>
//   balancers.uc set <config.json> <desired.json> [out-path]
// desired.json = [ { "tag":..., "selector":[...], "strategy":..., "fallbackTag":... }, ... ]
'use strict';
import { readfile, writefile } from 'fs';

let action = ARGV[0];
let cfg = json(readfile(ARGV[1]));

function outbound_tags() {
	let t = [], o = cfg.outbounds ?? [];
	for (let i = 0; i < length(o); i++) push(t, o[i].tag);
	return t;
}

// union two selector lists (dedup, order-stable enough), never removing members
function union_sel(existing, add) {
	let set = {}, out = [];
	for (let i = 0; i < length(existing); i++) set[existing[i]] = 1;
	for (let i = 0; i < length(add); i++) set[add[i]] = 1;
	for (let k in set) push(out, k);
	return out;
}

if (action == 'get') {
	let bals = [], arr = (cfg.routing && cfg.routing.balancers) ? cfg.routing.balancers : [];
	for (let i = 0; i < length(arr); i++) {
		let b = arr[i];
		push(bals, {
			tag: b.tag,
			selector: b.selector ?? [],
			strategy: (b.strategy && b.strategy.type) ? b.strategy.type : 'random',
			fallbackTag: b.fallbackTag ?? ''
		});
	}
	printf('%J\n', { balancers: bals, outbounds: outbound_tags() });
}
else if (action == 'set') {
	let desired = json(readfile(ARGV[2]));
	let out_path = ARGV[3];

	let bals = [], ping_sel = [], load_sel = [];
	for (let i = 0; i < length(desired); i++) {
		let d = desired[i];
		let b = { tag: d.tag, selector: d.selector ?? [], strategy: { type: d.strategy } };
		if (d.fallbackTag && length(d.fallbackTag)) b.fallbackTag = d.fallbackTag;
		push(bals, b);
		// leastPing is driven by `observatory`; leastLoad by `burstObservatory`.
		if (d.strategy == 'leastPing')
			for (let j = 0; j < length(b.selector); j++) push(ping_sel, b.selector[j]);
		else if (d.strategy == 'leastLoad')
			for (let j = 0; j < length(b.selector); j++) push(load_sel, b.selector[j]);
	}
	if (!cfg.routing) cfg.routing = {};
	cfg.routing.balancers = bals;

	// leastPing members: probed by the observatory (latency), union with existing
	if (length(ping_sel)) {
		let existing = (cfg.observatory && cfg.observatory.subjectSelector) ? cfg.observatory.subjectSelector : [];
		if (!cfg.observatory) cfg.observatory = {};
		cfg.observatory.subjectSelector = union_sel(existing, ping_sel);
		if (!cfg.observatory.probeUrl) cfg.observatory.probeUrl = 'https://www.gstatic.com/generate_204';
		if (!cfg.observatory.probeInterval) cfg.observatory.probeInterval = '30s';
	}

	// leastLoad members: probed by the burstObservatory (health/load ping), union
	if (length(load_sel)) {
		let existing = (cfg.burstObservatory && cfg.burstObservatory.subjectSelector) ? cfg.burstObservatory.subjectSelector : [];
		if (!cfg.burstObservatory) cfg.burstObservatory = {};
		cfg.burstObservatory.subjectSelector = union_sel(existing, load_sel);
		if (!cfg.burstObservatory.pingConfig) cfg.burstObservatory.pingConfig = {
			destination: 'http://www.gstatic.com/generate_204',
			interval: '30s', sampling: 3, timeout: '5s'
		};
	}

	let s = sprintf('%.2J', cfg);
	if (out_path) { writefile(out_path, s); printf('OK\n'); }
	else printf('%s\n', s);
}
