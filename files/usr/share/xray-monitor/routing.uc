#!/usr/bin/ucode
// Read/write the tproxy inbounds and their inbound->exit routing rules.
//   routing.uc get <config.json>
//   routing.uc set <config.json> <desired.json> [out-path]
// desired.json = [ { "tag":..., "port":..., "exit":... }, ... ]
'use strict';
import { readfile, writefile } from 'fs';

let action = ARGV[0];
let cfg = json(readfile(ARGV[1]));

// A "managed" inbound is a tproxy dokodemo-door (excludes the api/local inbound).
function is_managed_in(o) {
	return o.protocol == 'dokodemo-door' && o.streamSettings &&
	       o.streamSettings.sockopt && o.streamSettings.sockopt.tproxy == 'tproxy';
}

function balancer_set() {
	let b = {}, arr = (cfg.routing && cfg.routing.balancers) ? cfg.routing.balancers : [];
	for (let i = 0; i < length(arr); i++) b[arr[i].tag] = 1;
	return b;
}

// the exit (outboundTag/balancerTag) of the simple one-inbound rule for `tag`
function rule_exit_for(tag) {
	let rules = (cfg.routing && cfg.routing.rules) ? cfg.routing.rules : [];
	for (let i = 0; i < length(rules); i++) {
		let r = rules[i];
		if (r.type == 'field' && r.inboundTag && length(r.inboundTag) == 1 && r.inboundTag[0] == tag &&
		    !r.domain && !r.ip && !r.port && !r.protocol && !r.source && !r.user && !r.network)
			return r.balancerTag ?? r.outboundTag ?? '';
	}
	return '';
}

if (action == 'get') {
	let bs = balancer_set();
	let inbounds = [], ins = cfg.inbounds ?? [];
	for (let i = 0; i < length(ins); i++)
		if (is_managed_in(ins[i]))
			push(inbounds, { tag: ins[i].tag, port: ins[i].port, exit: rule_exit_for(ins[i].tag) });
	let exits = [], obs = cfg.outbounds ?? [];
	for (let i = 0; i < length(obs); i++) push(exits, { tag: obs[i].tag, kind: 'outbound' });
	for (let t in bs) push(exits, { tag: t, kind: 'balancer' });
	printf('%J\n', { inbounds: inbounds, exits: exits });
}
else if (action == 'set') {
	let desired = json(readfile(ARGV[2]));
	let out_path = ARGV[3];
	let bs = balancer_set();

	function mk_inbound(tag, port) {
		return {
			tag: tag, protocol: 'dokodemo-door', listen: '0.0.0.0', port: int(port),
			settings: { network: 'tcp,udp', followRedirect: true },
			sniffing: { enabled: true, destOverride: [ 'http', 'tls' ] },
			streamSettings: { sockopt: { tproxy: 'tproxy' } }
		};
	}

	// rebuild inbounds: keep non-managed (api/local), then the desired tproxy set
	let new_in = [], ins = cfg.inbounds ?? [], managed = {};
	for (let i = 0; i < length(ins); i++)
		if (is_managed_in(ins[i])) managed[ins[i].tag] = 1; else push(new_in, ins[i]);
	for (let i = 0; i < length(desired); i++) {
		managed[desired[i].tag] = 1;
		push(new_in, mk_inbound(desired[i].tag, desired[i].port));
	}
	cfg.inbounds = new_in;

	// drop old simple inbound->exit rules (old or new managed tags), keep everything else, add fresh
	function is_managed_rule(r) {
		if (r.type != 'field' || !r.inboundTag || length(r.inboundTag) != 1) return false;
		if (!managed[r.inboundTag[0]]) return false;
		if (r.domain || r.ip || r.port || r.protocol || r.source || r.user || r.network) return false;
		return true;
	}
	let kept = [], rules = (cfg.routing && cfg.routing.rules) ? cfg.routing.rules : [];
	for (let i = 0; i < length(rules); i++)
		if (!is_managed_rule(rules[i])) push(kept, rules[i]);
	for (let i = 0; i < length(desired); i++) {
		let d = desired[i];
		if (!d.exit || !length(d.exit)) continue;
		let r = { type: 'field', inboundTag: [ d.tag ] };
		if (bs[d.exit]) r.balancerTag = d.exit; else r.outboundTag = d.exit;
		push(kept, r);
	}
	if (!cfg.routing) cfg.routing = {};
	cfg.routing.rules = kept;

	let s = sprintf('%.2J', cfg);
	if (out_path) { writefile(out_path, s); printf('OK\n'); }
	else printf('%s\n', s);
}
