// Live balancer state + sticky overrides (F15).
//
// Pure helpers around the two Xray RoutingService API commands the Balancers
// tab uses:
//   xray api bi -json <tag>   -> what a balancer picks right now and whether a
//                                sticky override is active on it
//   xray api bo -b <tag> <ob> -> pin a balancer to one outbound (-r = unpin)
// bi answers, per balancer: `override.target` ("" = nothing pinned; protojson
// omits the empty string, so an unpinned balancer shows `"override": {}`) and
// `principleTarget.tag` - the strategy's current selection: for leastPing /
// leastLoad that is the node(s) it is picking, for random/roundRobin the whole
// candidate set (those pick per connection, there is no single answer).
//
// Module API (no fs/uci imports - everything is golden-tested in tests/run.sh):
//   map_bi(raw)         one bi reply -> { override, targets }
//   override_state(w, h) persisted vs running override -> 'ok'|'missing'|
//                       'drift'|'unexpected'
//   valid_tag(s)        the tag charset accepted from any client
//   validate_override() charset + membership check -> null | reason string
//   config_balancers()  routing.balancers of a config, defensively typed
//   config_outbound_tags()  all outbound tags of a config
//   members()           outbound tags a balancer's selectors stand for
//   build_live()        config + bi replies + UCI overrides -> UI snapshot
//   applicable_overrides() UCI overrides whose balancer still exists
//
// This file is a module only (ucode `export` is illegal in a main script);
// the CLI entry point is balance-cli.uc next to it.
'use strict';

// Charset of tags accepted anywhere (balancer / outbound identifiers). xray
// itself would accept more, but this is what the UI generates, and it keeps
// the layers that embed a tag into a filename, a UCI value or a JSON document
// injection-free.
function valid_tag(s) {
	return type(s) == 'string' && match(s, /^[A-Za-z0-9_.-]+$/) != null;
}

// One `xray api bi -json <tag>` reply -> the parts we use. Defensive against
// missing / oddly-typed fields: xray omits empty strings and whole blocks.
function map_bi(raw) {
	let o = (type(raw) == 'object') ? raw : {};
	let b = (type(o.balancer) == 'object') ? o.balancer : {};
	let ov = (type(b.override) == 'object' && type(b.override.target) == 'string') ? b.override.target : '';
	let pt = (type(b.principleTarget) == 'object' && type(b.principleTarget.tag) == 'array') ? b.principleTarget.tag : [];
	let targets = [];
	for (let i = 0; i < length(pt); i++)
		if (type(pt[i]) == 'string' && length(pt[i])) push(targets, pt[i]);
	return { override: ov, targets: targets };
}

// Divergence between the persisted override (UCI, w) and the running one
// (bi, h); "" on either side = no override there.
//   ok         both agree (including "no override anywhere")
//   missing    UCI has one, the running xray does not - a restart (ours or an
//              external one) dropped the in-memory table; re-apply fixes it
//   drift      both set but different targets - something else (CLI, another
//              session) pinned after our pin did
//   unexpected nothing persisted here, but the running xray has an override
function override_state(want, have) {
	let w = (type(want) == 'string') ? want : '';
	let h = (type(have) == 'string') ? have : '';
	if (w == h) return 'ok';
	if (w == '') return 'unexpected';
	if (h == '') return 'missing';
	return 'drift';
}

// Validate an override pair for balancer_override_set. Membership, not just
// charset: bo would happily pin a balancer to a tag that does not exist and
// the balancer would then route into the void, so the pair is checked against
// the CURRENT config. `outbound` may be "" (means "clear the override").
// Returns null when valid, else a short reason for the UI.
function validate_override(balancer, outbound, balancer_tags, outbound_tags) {
	if (!valid_tag(balancer)) return 'invalid balancer tag';
	if (type(outbound) != 'string' || (length(outbound) && !valid_tag(outbound)))
		return 'invalid outbound tag';
	let i, hit = false;
	for (i = 0; i < length(balancer_tags); i++) if (balancer_tags[i] == balancer) hit = true;
	if (!hit) return 'no such balancer in the config';
	if (!length(outbound)) return null;
	hit = false;
	for (i = 0; i < length(outbound_tags); i++) if (outbound_tags[i] == outbound) hit = true;
	return hit ? null : 'no such outbound in the config';
}

// routing.balancers of a parsed config as { tag, strategy, selector } records,
// never trusting the shape of a hand-edited file.
function config_balancers(cfg) {
	let arr = (type(cfg) == 'object' && type(cfg.routing) == 'object' && type(cfg.routing.balancers) == 'array')
		? cfg.routing.balancers : [];
	let out = [];
	for (let i = 0; i < length(arr); i++) {
		let b = (type(arr[i]) == 'object') ? arr[i] : {};
		push(out, {
			tag: (type(b.tag) == 'string') ? b.tag : '',
			strategy: (type(b.strategy) == 'object' && type(b.strategy.type) == 'string') ? b.strategy.type : 'random',
			selector: (type(b.selector) == 'array') ? b.selector : []
		});
	}
	return out;
}

// All outbound tags of a parsed config (order kept).
function config_outbound_tags(cfg) {
	let obs = (type(cfg) == 'object' && type(cfg.outbounds) == 'array') ? cfg.outbounds : [];
	let out = [];
	for (let i = 0; i < length(obs); i++)
		if (type(obs[i]) == 'object' && type(obs[i].tag) == 'string') push(out, obs[i].tag);
	return out;
}

// Selector entries are prefixes: an outbound is a member when its tag equals a
// selector or starts with `<selector>-` (the same ownership rule render.uc
// applies to subscription prefixes).
function members(selector, outbound_tags) {
	let out = [];
	for (let i = 0; i < length(outbound_tags); i++) {
		let t = outbound_tags[i];
		for (let j = 0; j < length(selector); j++) {
			let p = selector[j];
			if (type(p) != 'string' || !length(p)) continue;
			if (t == p || substr(t, 0, length(p) + 1) == p + '-') { push(out, t); break; }
		}
	}
	return out;
}

// The live snapshot rendered by the Balancers tab (the body the rpcd
// balancers_live method returns):
//   { api, balancers: [ ...one record per CONFIG balancer... ], stale: [ ... ] }
// record: { tag, strategy, members, live, pick, targets, overrideLive,
//           overrideUci, state }
//   live         the bi call for this balancer answered
//   pick         the single outbound in use right now: the override when one
//                is active, else the leastPing/leastLoad pick; "" for
//                random/roundRobin (per-connection choice, see targets)
//   overrideLive sticky override active on the running xray ("" = none)
//   overrideUci  persisted override from UCI ("" = none)
//   state        override_state(overrideUci, overrideLive)
// stale: persisted overrides of balancers that no longer exist in the config.
// bi_map: { tag -> parsed bi reply }; a missing key or an `{ "error": true }`
// marker counts as "call failed" (live=false, overrides unknowable).
function build_live(cfg, bi_map, uci_overrides) {
	let bals = config_balancers(cfg), otags = config_outbound_tags(cfg);
	let bybal = {};
	let ovs = (type(uci_overrides) == 'array') ? uci_overrides : [];
	for (let i = 0; i < length(ovs); i++) {
		let o = (type(ovs[i]) == 'object') ? ovs[i] : {};
		if (type(o.balancer) == 'string' && length(o.balancer) &&
		    type(o.outbound) == 'string' && length(o.outbound))
			bybal[o.balancer] = o.outbound;   // last section wins on duplicates
	}
	let out = [], stale = [], anylive = false;
	for (let i = 0; i < length(bals); i++) {
		let b = bals[i];
		let raw = exists(bi_map, b.tag) ? bi_map[b.tag] : null;
		let ok = (type(raw) == 'object' && !exists(raw, 'error'));
		let m = ok ? map_bi(raw) : { override: '', targets: [] };
		if (ok) anylive = true;
		let uci = exists(bybal, b.tag) ? bybal[b.tag] : '';
		let pick = (m.override != '') ? m.override
			: ((b.strategy == 'leastPing' || b.strategy == 'leastLoad') ? (m.targets[0] ?? '') : '');
		push(out, {
			tag: b.tag,
			strategy: b.strategy,
			members: members(b.selector, otags),
			live: ok,
			pick: pick,
			targets: m.targets,
			overrideLive: m.override,
			overrideUci: uci,
			state: override_state(uci, m.override)
		});
		delete bybal[b.tag];
	}
	for (let k in bybal) push(stale, { balancer: k, outbound: bybal[k] });
	return { api: (anylive || !length(bals)), balancers: out, stale: stale };
}

// Overrides whose balancer still exists in the config - exactly the set `xray
// api bo` can (re-)apply; bo rejects unknown balancer tags ("cannot find
// tag"), so stale sections are dropped here instead of reported as failures
// on every restart.
function applicable_overrides(cfg, overrides) {
	let tags = {}, bals = config_balancers(cfg);
	for (let i = 0; i < length(bals); i++) tags[bals[i].tag] = 1;
	let ovs = (type(overrides) == 'array') ? overrides : [];
	let out = [];
	for (let i = 0; i < length(ovs); i++) {
		let o = (type(ovs[i]) == 'object') ? ovs[i] : {};
		if (type(o.balancer) == 'string' && exists(tags, o.balancer) &&
		    type(o.outbound) == 'string' && length(o.outbound))
			push(out, { balancer: o.balancer, outbound: o.outbound });
	}
	return out;
}

export {
	map_bi, override_state, valid_tag, validate_override,
	config_balancers, config_outbound_tags, members,
	build_live, applicable_overrides
};
