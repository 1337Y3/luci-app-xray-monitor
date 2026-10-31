#!/usr/bin/ucode
// Exit selection for proxied fetches / self-updates (F18) from the e2e results
// F13 writes (contract B3): /tmp/xray-monitor/e2e.json =
//   {"ts":N,"results":{"<tag>":{"status":"ok|stalled|fail|skipped",
//    "ttfb_ms":N,"bytes":N,"speed_bps":N,"ts":N}}}
//   pickexit.uc <e2e.json> <now-epoch> [max-age-s, default 3600]
// Prints the winning tag (rc 0), or prints nothing and exits 1 when the file
// is absent/unreadable/unparseable, STALE, or holds no result with status
// "ok" - the caller (xray-sub via_pick_exit) then falls back to the rpcd
// probe surface. Stale = top-level ts older than max-age, or more than 300 s
// in the future (a wrong clock must not keep a months-old run "fresh").
// Winner: the result with status "ok" and the highest speed_bps; equal speeds
// keep document order (first wins) - ucode objects iterate in insertion order,
// and json() preserves the file's order.
'use strict';
import { readfile } from 'fs';

if (length(ARGV) < 2)
	die('usage: pickexit.uc <e2e.json> <now> [max-age]\n');

let max_age = int(ARGV[2] ?? 3600);
if (max_age <= 0) max_age = 3600;

let raw = readfile(ARGV[0]);
if (!raw) exit(1);                       // absent or unreadable

let data;
try { data = json(raw); } catch (e) { exit(1); }

let ts = int(data.ts ?? 0);
if (ts <= 0) exit(1);                    // not an e2e result file
let now = int(ARGV[1]);
if (now - ts > max_age) exit(1);         // stale: measurements predate the exits
if (ts - now > 300) exit(1);             // from the future: clock skew

let best = null, best_bps = -1;
let results = (type(data.results) == 'object') ? data.results : {};
for (let tag in results) {
	let r = results[tag];
	if (type(r) != 'object' || r.status != 'ok') continue;
	let bps = int(r.speed_bps ?? 0);
	if (bps > best_bps) { best_bps = bps; best = tag; }
}
if (!best) exit(1);                      // e2e ran but nothing passed

print(best + '\n');
