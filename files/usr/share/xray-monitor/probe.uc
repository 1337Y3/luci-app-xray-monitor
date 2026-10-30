#!/usr/bin/ucode
// Bare TCP reachability probe: connect, send NOTHING, close. No TLS/HTTP
// handshake - poking a blocked exit with a ClientHello can trigger an ISP
// reset, a plain SYN cannot. Connect is capped at ~3s via SO_SNDTIMEO.
//   probe.uc <host> <port>   ->  "1 <ms>"   on successful connect
// A refused/unreachable connect raises inside ucode (no try/catch) and aborts
// the script with empty output - the shell caller maps that to "0 0".
// Latency comes from /proc/uptime (10 ms resolution): BusyBox date on 23.05
// has no sub-second support.
'use strict';
import { create, AF_INET, AF_INET6, SOCK_STREAM, SOL_SOCKET, SO_SNDTIMEO } from 'socket';
import { readfile } from 'fs';

let host = ARGV[0] ?? '', port = ARGV[1] ?? '';

function now_ms() {
	let up = split(trim(readfile('/proc/uptime') ?? '0.00'), ' ');
	let p = split(up[0] ?? '0.00', '.');
	return int(p[0]) * 1000 + ((length(p) > 1) ? int(substr(p[1], 0, 2)) * 10 : 0);
}

let v6 = index(host, ':') >= 0;
let target = v6 ? ('[' + host + ']:' + port) : (host + ':' + port);
let s = create(v6 ? AF_INET6 : AF_INET, SOCK_STREAM);
s.setopt(SOL_SOCKET, SO_SNDTIMEO, [ 3, 0 ]);
let t0 = now_ms();
let ok = s.connect(target);
let dt = now_ms() - t0;
s.close();
if (ok) print('1 ' + dt + '\n');
