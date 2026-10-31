#!/usr/bin/ucode
// End-to-end exit check helpers (F13, contract B3). The TCP probe calls an
// exit "reachable" while DPI (TSPU) lets the handshake through and freezes the
// stream after the first ~16-20 KB; only pulling a real body through the exit
// separates usable from dead. xray-sub `e2e` drives tmpxray + curl; this file
// holds the pure parts so they are golden-testable:
//   e2e.uc verdict <r204> <rbody>   classify one exit's two fetches
//       r204  = {"rc":N,"http":N,"ttfb_ms":N}          (the 204/TTFB fetch)
//       rbody = {"rc":N,"http":N,"bytes":N,"expected":N,"speed_bps":N}
//     -> {"status":"ok|stalled|fail","ttfb_ms":N,"bytes":N,"speed_bps":N}
//       ok      curl delivered the whole body: rc 0, HTTP 2xx/3xx, and
//               bytes >= expected when the URL is size-exact (a %d size
//               placeholder); expected 0 (fixed-size URL) only needs the
//               transfer to finish with a nonzero body
//       stalled data flowed but the body never finished within curl's budget:
//               curl timed out (rc 28) or the transfer ended short - bytes
//               received but < expected, HTTP still 2xx/3xx. The freeze
//               signature: a few KB arrive, then silence
//       fail    nothing usable came through: connect/proxy/TLS error, an
//               HTTP error status (>= 400), or zero body bytes
//   e2e.uc skipped              the probe_disabled record (never dialled)
//   e2e.uc tags <config.json>   probeable exit tags, one per line, config
//                               order: outbounds whose settings carry a
//                               server endpoint (vnext[0]/servers[0].address),
//                               the same rule the rpcd probe list uses
//   e2e.uc merge <e2e.json> <run_ts> <tag> <record>
//                               read e2e.json (fresh when absent/unparsable),
//                               set results[tag] = record (stamping the
//                               record's ts when absent), set ts = run_ts and
//                               print the whole file to stdout. The caller
//                               redirects to <path>.new and mv's it into
//                               place, so polling readers never see a torn
//                               file. Tag charset is validated ([A-Za-z0-9._-])
//   e2e.uc status <e2e.json> <0|1>
//                               -> {"running":bool,"ts":N,"results":{...}}
//                                 (the file content plus the run flag; the
//                                  flag lives in e2e.run, not in e2e.json,
//                                  to keep contract B3 exact)
//   e2e.uc summary <e2e.json>   one line per exit plus a "# ..." count line
//                               (CLI/cron log output)
'use strict';
import { readfile } from 'fs';

function num(v) {
	return int(v ?? 0);
}

function verdict(r204, rbody) {
	let r = (type(r204) == 'object') ? r204 : {};
	let b = (type(rbody) == 'object') ? rbody : {};
	let ttfb = num(r.ttfb_ms);
	let http = num(b.http), bytes = num(b.bytes), expected = num(b.expected);
	let http_ok = (http >= 200 && http < 400);
	// ok: the body arrived in full. `expected <= 0` means the URL has no size
	// placeholder - "finished" is judged by curl rc alone there.
	if (num(b.rc) == 0 && http_ok && bytes > 0 && (expected <= 0 || bytes >= expected))
		return { status: 'ok', ttfb_ms: ttfb, bytes: bytes, speed_bps: num(b.speed_bps) };
	// stalled: some body bytes arrived, HTTP was fine, but the transfer did
	// not complete - the "16 KB then silence" DPI freeze signature.
	if (bytes > 0 && http_ok)
		return { status: 'stalled', ttfb_ms: ttfb, bytes: bytes, speed_bps: num(b.speed_bps) };
	return { status: 'fail', ttfb_ms: ttfb, bytes: bytes, speed_bps: 0 };
}

function print_tags(cfg_path) {
	let cfg = json(readfile(cfg_path));
	if (type(cfg) != 'object') { warn('not a JSON object\n'); exit(1); }
	let obs = (type(cfg.outbounds) == 'array') ? cfg.outbounds : [];
	for (let i = 0; i < length(obs); i++) {
		let o = obs[i];
		let s = (type(o.settings) == 'object') ? o.settings : {};
		let has = (type(s.vnext) == 'array' && type(s.vnext[0]) == 'object' && s.vnext[0].address)
		       || (type(s.servers) == 'array' && type(s.servers[0]) == 'object' && s.servers[0].address);
		if (o.tag && has)
			print(o.tag + '\n');
	}
}

function load_e2e(path) {
	let raw = readfile(path);
	if (raw) {
		let d = json(raw);
		if (type(d) == 'object') {
			if (type(d.results) != 'object') d.results = {};
			return d;
		}
	}
	return { ts: 0, results: {} };
}

function merge(path, run_ts, tag, record) {
	if (!match(tag, /^[A-Za-z0-9._-]+$/)) { warn('invalid tag\n'); exit(1); }
	if (type(record) != 'object') { warn('record is not a JSON object\n'); exit(1); }
	if (!record.ts) record.ts = time();
	let d = load_e2e(path);
	d.results[tag] = record;
	d.ts = num(run_ts);
	print(sprintf('%J\n', d));
}

function print_status(path, running) {
	let d = load_e2e(path);
	let run = (running == '1' || running == 'true' || running == 1) ? true : false;
	print(sprintf('%J\n', { running: run, ts: num(d.ts), results: d.results }));
}

function print_summary(path) {
	let d = load_e2e(path);
	let ks = keys(d.results);
	let n = { ok: 0, stalled: 0, fail: 0, skipped: 0 };
	for (let i = 0; i < length(ks); i++) {
		let r = d.results[ks[i]];
		if (type(r) != 'object') continue;
		let st = '' + (r.status ?? '');
		if (!(st in n)) n[st] = 0;
		n[st] = n[st] + 1;
		printf('%-16s %-8s %7s ms %10s B %9s B/s\n',
			ks[i], st, '' + num(r.ttfb_ms), '' + num(r.bytes), '' + num(r.speed_bps));
	}
	printf('# ok=%d stalled=%d fail=%d skipped=%d\n', n.ok, n.stalled, n.fail, n.skipped);
}

if (ARGV[0] == 'verdict' && length(ARGV) == 3) {
	print(sprintf('%J\n', verdict(json(ARGV[1]), json(ARGV[2]))));
} else if (ARGV[0] == 'skipped' && length(ARGV) == 1) {
	print(sprintf('%J\n', { status: 'skipped', ttfb_ms: 0, bytes: 0, speed_bps: 0 }));
} else if (ARGV[0] == 'tags' && length(ARGV) == 2) {
	print_tags(ARGV[1]);
} else if (ARGV[0] == 'merge' && length(ARGV) == 5) {
	merge(ARGV[1], ARGV[2], ARGV[3], json(ARGV[4]));
} else if (ARGV[0] == 'status' && length(ARGV) == 3) {
	print_status(ARGV[1], ARGV[2]);
} else if (ARGV[0] == 'summary' && length(ARGV) == 2) {
	print_summary(ARGV[1]);
} else {
	warn('usage: e2e.uc verdict <r204> <rbody> | skipped | tags <config.json>' +
	     ' | merge <e2e.json> <run_ts> <tag> <record> | status <e2e.json> <0|1>' +
	     ' | summary <e2e.json>\n');
	exit(1);
}
