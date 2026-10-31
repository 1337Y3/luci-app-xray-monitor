#!/usr/bin/ucode
// CLI front end for the balance module (F15). Used by the rpcd backend
// (balancers_live / balancer_override_set) and by xray-sub (overrides_apply),
// and golden-tested by tests/run.sh.
//   balance-cli.uc live <config.json> <bi-dir> <overrides.json> [ts]
//       merged live snapshot for the Balancers tab:
//       the config's balancers + their `xray api bi` replies + the persisted
//       (UCI) overrides. <bi-dir>/<tag>.bi holds the raw bi reply of that
//       balancer; a missing file or an {"error":true} marker = call failed.
//   balance-cli.uc validate <config.json> <balancer> <outbound>
//       {"ok":1} | {"ok":0,"msg":"<reason>"}   (outbound "" = clear, fine)
//   balance-cli.uc applicable <config.json> <overrides.json>
//       one "<balancer> <outbound>" line per persisted override whose
//       balancer still exists in the config
'use strict';
import { readfile, stderr } from 'fs';
import {
	build_live, applicable_overrides, validate_override,
	config_balancers, config_outbound_tags
} from 'balance';

function usage() {
	stderr.write('usage: balance-cli.uc live <config> <bi-dir> <overrides.json> [ts]\n' +
	             '       balance-cli.uc validate <config> <balancer> <outbound>\n' +
	             '       balance-cli.uc applicable <config> <overrides.json>\n');
	exit(1);
}

function load_cfg(path) {
	let raw = readfile(path);
	return (raw != null && length(raw)) ? json(raw) : {};
}

if (length(ARGV) < 3) usage();

if (ARGV[0] == 'live') {
	if (length(ARGV) < 4) usage();
	let cfg = load_cfg(ARGV[1]);
	let ov_raw = readfile(ARGV[3]);
	let ovr = (ov_raw != null && length(ov_raw)) ? json(ov_raw) : [];
	// one file per balancer tag; a read error or an unparsable reply counts
	// as a failed call, never as a broken whole snapshot
	let bi_map = {};
	let bals = config_balancers(cfg);
	for (let i = 0; i < length(bals); i++) {
		let raw = readfile(ARGV[2] + '/' + bals[i].tag + '.bi');
		bi_map[bals[i].tag] = (raw != null && length(raw)) ? json(raw) : { error: true };
	}
	let snap = build_live(cfg, bi_map, ovr);
	snap.ts = (match(ARGV[4] ?? '', /^[0-9]+$/) != null) ? int(ARGV[4]) : 0;
	printf('%J\n', snap);
}
else if (ARGV[0] == 'validate') {
	let cfg = load_cfg(ARGV[1]);
	let bt = [], ot = config_outbound_tags(cfg), bals = config_balancers(cfg);
	for (let i = 0; i < length(bals); i++) push(bt, bals[i].tag);
	let reason = validate_override(ARGV[2] ?? '', ARGV[3] ?? '', bt, ot);
	if (reason == null) printf('{"ok":1}\n');
	// reason strings are our own fixed literals - safe to embed verbatim
	else printf('{"ok":0,"msg":"%s"}\n', reason);
}
else if (ARGV[0] == 'applicable') {
	let list = applicable_overrides(load_cfg(ARGV[1]), json(readfile(ARGV[2]) ?? '[]'));
	for (let i = 0; i < length(list); i++)
		printf('%s %s\n', list[i].balancer, list[i].outbound);
}
else {
	usage();
}
