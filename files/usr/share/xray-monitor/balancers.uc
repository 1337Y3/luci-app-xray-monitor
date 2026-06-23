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

	let bals = [], probe_needed = [];
	for (let i = 0; i < length(desired); i++) {
		let d = desired[i];
		let b = { tag: d.tag, selector: d.selector ?? [], strategy: { type: d.strategy } };
		if (d.fallbackTag && length(d.fallbackTag)) b.fallbackTag = d.fallbackTag;
		push(bals, b);
		if (d.strategy == 'leastPing' || d.strategy == 'leastLoad')
			for (let j = 0; j < length(b.selector); j++) push(probe_needed, b.selector[j]);
	}
	if (!cfg.routing) cfg.routing = {};
	cfg.routing.balancers = bals;

	// observatory must probe members of ping/load balancers (union with existing, never removing)
	if (length(probe_needed)) {
		let existing = (cfg.observatory && cfg.observatory.subjectSelector) ? cfg.observatory.subjectSelector : [];
		let set = {};
		for (let i = 0; i < length(existing); i++) set[existing[i]] = 1;
		for (let i = 0; i < length(probe_needed); i++) set[probe_needed[i]] = 1;
		let sel = [];
		for (let k in set) push(sel, k);
		if (!cfg.observatory) cfg.observatory = {};
		cfg.observatory.subjectSelector = sel;
		if (!cfg.observatory.probeUrl) cfg.observatory.probeUrl = 'https://www.gstatic.com/generate_204';
		if (!cfg.observatory.probeInterval) cfg.observatory.probeInterval = '30s';
	}

	let s = sprintf('%.2J', cfg);
	if (out_path) { writefile(out_path, s); printf('OK\n'); }
	else printf('%s\n', s);
}
