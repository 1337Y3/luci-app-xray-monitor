#!/usr/bin/ucode
// Hot-swap plan for subscription outbound changes (F14): decide whether the
// difference between the installed config.json and an apply candidate can be
// reconciled LIVE via `xray api rmo`/`ado` (no restart), and produce the exact
// remove/add tag lists for it.
//
// ---------------------------------------------------------------------------
// STEP-0 CONCLUSIONS FROM THE XRAY-CORE SOURCES (clone @ XTLS/Xray-core,
// verified against the running 26.10.21 on the router; file paths relative to
// the repo root). These are the facts the plan rules below are built on:
//
// 1. app/proxyman/command/command.go (HandlerService):
//    - AddOutbound  -> core.AddOutboundHandler (core/xray.go): builds the
//      handler through the same object registry as a config-file load, then
//      outbound.Manager.AddHandler. Every outbound protocol - incl. all four
//      managed ones (vless/vmess/trojan/shadowsocks) - is an ordinary outbound
//      handler, so ALL are live-addable.
//    - RemoveOutbound -> outbound.Manager.RemoveHandler.
//    - ListOutbounds returns every user outbound's tag; the commander's
//      internal gRPC outbound is skipped, and the order is random (Go map
//      iteration) - only the SET of lso tags is meaningful.
// 2. app/proxyman/outbound/outbound.go:
//    - AddHandler FAILS with "existing tag found: <tag>" if the tag is already
//      registered -> a changed outbound body must be remove(tag) THEN
//      add(tag); adds are only safe after the removals.
//    - RemoveHandler only deletes the tag from the map. It does NOT Close the
//      handler: in-flight connections keep their reference and run to their
//      natural end. Only NEW dispatches to a missing tag are affected (see 3).
//    - defaultHandler: set by the FIRST AddHandler when still nil, i.e. the
//      first outbound of the config xray started with; RemoveHandler nils it
//      exactly when its own tag is removed, and the first add afterwards
//      claims it. There is no API to read or set the default handler, so a
//      hot-swap must preserve it by construction (rule D below).
//    - Manager.Select(selectors) resolves selector prefixes against the LIVE
//      tag map; its tagsCache is reset on every AddHandler/RemoveHandler.
// 3. app/dispatcher/default.go (routedDispatch): the outbound tag of a routing
//    rule or balancer pick is resolved per connection via GetHandler. A tag
//    that is missing logs "non existing outTag" and the connection is DROPPED
//    - it never falls back to the default outbound. So removing a tag that a
//    rule still references breaks that rule's new connections until the tag is
//    re-added or the rule is updated (a remove+add pair leaves only a
//    millisecond window; a plain removal is intentional in the new config
//    anyway - identical to what a restart would produce).
// 4. app/router/balancing.go: Balancer.PickOutbound calls SelectOutbounds ->
//    ohm.Select on EVERY pick, so balancer membership follows outbound
//    add/remove live; the per-balancer override (`xray api bo`) is consulted
//    before the strategy and is in-memory state of the Balancer object.
// 5. app/observatory/observer.go (and burst/burstobserver.go): the background
//    loop re-resolves subjectSelector via the same live Select on EVERY probe
//    round and prunes status entries of removed outbounds
//    (clearRemovedOutbounds). No restart is needed for the observatory to see
//    new/removed members - but see 6 for the strategy-visible delay.
// 6. app/router/strategy_leastping.go / strategy_leastload.go: only tags that
//    HAVE an observation entry and are Alive are selectable. A newly added
//    member is therefore not chosen by leastPing/leastLoad until its first
//    probe completes (<= one probe round; probeInterval, default 10 s).
//    RoundRobin (balancing.go) treats unobserved candidates as alive and
//    picks them immediately. Membership itself still updates live - this is a
//    bounded convergence delay, not a restart case.
// 7. There is no AlterOutbound operation in the tree (no ApplyOutbound
//    implementations besides the interface declaration in
//    app/proxyman/command/command.go) - remove+add is the ONLY live way to
//    change an outbound body.
// 8. main/commands/all/api/{outbounds_add,outbounds_remove,outbounds_list}.go:
//    `ado`/`rmo` take config JSON files (rmo also bare tag args; a tag that
//    happens to name a readable file would be parsed as a file, so the shell
//    passes tags via a JSON file, never as args); each call has a bounded
//    timeout (-t, default 3 s); rmo of an unknown tag is a silent success
//    (RemoveHandler cannot fail on a missing tag), ado aborts on the first
//    error having applied the earlier outbounds of the same call.
//
// RESTART IS STILL REQUIRED when anything beyond managed outbound membership
// changes, because none of it is reconciled by rmo/ado (and the apply writer
// must not try): inbounds (AddInbound/RemoveInbound exist but are out of
// scope), routing rules (RouterService AddRule/RemoveRule replace the whole
// rule set via ReloadRules, app/router/router.go - which also rebuilds every
// balancer and thereby DROPS their in-memory overrides), balancer config
// (selector/strategy/fallbackTag), observatory/policy config (built once at
// startup), the local (non-managed) outbounds, or any other config section.
// Plus the default-outbound rule D below. Honesty over cleverness: anything
// the plan cannot guarantee is restarted.
//
// PLAN RULES (candidate = what the running xray must equal afterwards):
//   M (membership) remove = managed tags of the installed config absent from
//     the candidate or whose body changed (bodies compared via canonsig with
//     the same ignore list as diff.uc); add = managed tags of the candidate
//     absent from the installed config or changed, in CANDIDATE order (the
//     caller MUST ado in exactly this order - see D).
//   B (beyond) the candidate and the installed config must be identical once
//     the managed outbounds are removed from both (all other sections + the
//     local outbounds, order included). Otherwise: restart.
//   T (tag charset) every tag in remove/add must match [A-Za-z0-9._-] (the
//     same set the shell side builds its rmo JSON with and do_tmpxray_start
//     pins test inbounds to). A tag with a space, quote or slash is a legal
//     xray tag and still managed by the prefix rule, but the shell hands tags
//     around unquoted (word splitting) - it would decompose into individually
//     legal fragments, rmo would no-op, the set verify would fail, and the
//     fallback would restore a config carrying the same bad tag: an
//     apply-fails-forever loop while hot_swap=1. Detected HERE, at plan time,
//     so such a change simply restarts (reason "tag-charset").
//   D (default outbound) the running default handler is the first outbound of
//     the config xray started with (= the installed config.json); a restart
//     with the candidate would make the candidate's first outbound the
//     default. After "all removals, then adds in candidate order" the running
//     default is: the installed first tag when it was NOT removed, else the
//     first added tag. Hot-swap is allowed only when that equals the
//     candidate's first tag:
//       - installed-first removed  -> candidate-first must be in `add`
//       - installed-first kept     -> candidate-first must equal it
// ---------------------------------------------------------------------------
//
// Usage:
//   hotswap.uc plan <installed.json> <candidate.json> [prefix ...] [ignore=dot.path ...]
//     -> {"remove":[tag...],"add":[tag...],"changed":[tag...],
//         "first_old":"t","first_new":"t",
//         "restart_required":null|"changes-beyond-outbounds"|"tag-charset"|"default-outbound",
//         "hot_swap":true|false}
//     remove is installed-order, add is candidate-order; restart_required is
//     null exactly when the change is live-applicable (hot_swap true).
//     NOTE: the first two argv are <installed> <candidate> - deliberately the
//     Ignore paths travel as `ignore=<path>` args (see diff.uc's header: the
//     23.05 ucode swallows a literal `--` from ARGV, so a `--` separator would
//     feed every ignore path into `prefixes` there; prefixes cannot contain `=`).
//     NOTE: the first two argv are <installed> <candidate> - deliberately the
//     reverse of the sibling diff.uc (<staged> <config>): diff shows the staged
//     groups against the installed config, while plan must lead with the OLD
//     installed config because that is what the RUNNING xray was started from.
//   hotswap.uc adds <candidate.json> <tag> ...
//     -> {"outbounds":[...]} with the full bodies of the given tags, in
//     CANDIDATE order (not argument order) - the file for `xray api ado`.
//     Unknown tags are an error (exit 1).
'use strict';
import { readfile } from 'fs';
import { owner_prefix } from 'render';
import { canonsig, deep_copy } from 'jsondiff';

let proxy_protos = [ 'vless', 'vmess', 'trojan', 'shadowsocks' ];

function prune(o, path) {  // same semantics as diff.uc
	let segs = split(path, '.');
	let cur = o;
	for (let i = 0; i < length(segs) - 1; i++) {
		if (type(cur) != 'object' || !exists(cur, segs[i])) return;
		cur = cur[segs[i]];
	}
	if (type(cur) == 'object') delete cur[segs[length(segs) - 1]];
}

function body_of(o, ignores) {  // whole body minus tag minus ignored dot-paths
	// deep copy - prune() below deletes NESTED keys, and a shallow copy would
	// corrupt the parsed document the outbound was taken from
	let c = deep_copy(o);
	delete c.tag;
	for (let i = 0; i < length(ignores); i++) prune(c, ignores[i]);
	return canonsig(c);
}

// The plan logic (kept in one function so the CLI modes stay thin; this file
// is a script, not an importable module - ucode cannot be both).
// prefixes: array (empty = legacy "every tagged proxy outbound is managed").
function plan(installed, candidate, prefixes, ignores) {
	function managed(o) {
		if (!o || !o.tag || !length(o.tag)) return false;
		if (!(o.protocol in proxy_protos)) return false;   // same rule as diff.uc/apply.uc
		if (!length(prefixes)) return true;
		return owner_prefix(o.tag, prefixes) != null;
	}
	let old_obs = installed.outbounds ?? [], new_obs = candidate.outbounds ?? [];
	let oldm = {}, newm = {};
	for (let i = 0; i < length(old_obs); i++)
		if (managed(old_obs[i])) oldm[old_obs[i].tag] = body_of(old_obs[i], ignores);
	for (let i = 0; i < length(new_obs); i++)
		if (managed(new_obs[i])) newm[new_obs[i].tag] = body_of(new_obs[i], ignores);

	// M: remove in installed order (rmo), add in candidate order (ado - the
	// order is load-bearing for the default handler, rule D).
	let remove = [], add = [], changed = [];
	for (let i = 0; i < length(old_obs); i++) {
		let t = old_obs[i].tag;
		if (!exists(oldm, t)) continue;
		if (!exists(newm, t)) { push(remove, t); continue; }
		if (oldm[t] != newm[t]) { push(remove, t); push(changed, t); }
	}
	for (let i = 0; i < length(new_obs); i++) {
		let t = new_obs[i].tag;
		if (!exists(newm, t)) continue;
		if (!exists(oldm, t) || oldm[t] != newm[t]) push(add, t);
	}

	// B: everything except the managed outbounds must be identical. Object key
	// order does not matter (canonsig sorts); array order - the locals inside
	// outbounds included - does.
	let rest_old = {}, rest_new = {};
	for (let k in installed) rest_old[k] = installed[k];
	for (let k in candidate) rest_new[k] = candidate[k];
	delete rest_old.outbounds;
	delete rest_new.outbounds;
	rest_old['x-local-outbounds'] = [];
	rest_new['x-local-outbounds'] = [];
	for (let i = 0; i < length(old_obs); i++)
		if (!managed(old_obs[i])) push(rest_old['x-local-outbounds'], old_obs[i]);
	for (let i = 0; i < length(new_obs); i++)
		if (!managed(new_obs[i])) push(rest_new['x-local-outbounds'], new_obs[i]);
	let beyond = (canonsig(rest_old) != canonsig(rest_new));

	// T: any tag that would travel through rmo/ado must survive the shell's
	// unquoted word splitting AND the hand-built rmo JSON (rule T above).
	function legal_tag(t) { return !!(match(t, /^[A-Za-z0-9._-]+$/)); }
	let charset_ok = true;
	for (let i = 0; i < length(remove); i++) if (!legal_tag(remove[i])) charset_ok = false;
	for (let i = 0; i < length(add); i++) if (!legal_tag(add[i])) charset_ok = false;

	// D: keep the running default outbound equal to the candidate's first.
	let fo = length(old_obs) ? (old_obs[0].tag ?? '') : '';
	let fn = length(new_obs) ? (new_obs[0].tag ?? '') : '';
	let rm_set = {}, ad_set = {};
	for (let i = 0; i < length(remove); i++) rm_set[remove[i]] = 1;
	for (let i = 0; i < length(add); i++) ad_set[add[i]] = 1;

	let reason = null;
	if (beyond) reason = 'changes-beyond-outbounds';
	else if (!charset_ok) reason = 'tag-charset';
	else if (exists(rm_set, fo)) { if (!exists(ad_set, fn)) reason = 'default-outbound'; }
	else if (fo != fn) reason = 'default-outbound';

	return {
		remove: remove, add: add, changed: changed,
		first_old: fo, first_new: fn,
		restart_required: reason,
		hot_swap: (reason == null)
	};
}

if (ARGV[0] == 'plan') {
	let prefixes = [], ignores = [];
	for (let i = 3; i < length(ARGV); i++) {
		if (substr(ARGV[i], 0, 7) == 'ignore=') push(ignores, substr(ARGV[i], 7));
		else push(prefixes, ARGV[i]);
	}
	if (!length(ignores)) push(ignores, 'streamSettings.realitySettings.spiderX');
	let installed = json(readfile(ARGV[1]));
	let candidate = json(readfile(ARGV[2]));
	printf('%J\n', plan(installed, candidate, prefixes, ignores));
}
else if (ARGV[0] == 'adds') {
	// Bodies for `xray api ado`, in candidate order. ado aborts mid-file on an
	// error but keeps what it already added - the shell falls back to a full
	// restart on any failure, so partial application never survives.
	let cfg = json(readfile(ARGV[1]));
	let want = {};
	for (let i = 2; i < length(ARGV); i++) want[ARGV[i]] = 1;
	let obs = cfg.outbounds ?? [], out = [];
	for (let i = 0; i < length(obs); i++) {
		let t = obs[i].tag ?? '';
		if (exists(want, t)) { push(out, obs[i]); delete want[t]; }
	}
	let missing = keys(want);
	if (length(missing))
		die(sprintf('tags not found in candidate: %s', join(' ', sort(missing))));
	printf('%J\n', { outbounds: out });
}
else {
	warn('usage: hotswap.uc plan <installed> <candidate> [prefix ...] [ignore=dot.path ...]\n' +
	     '       hotswap.uc adds <candidate> <tag> ...\n');
	exit(1);
}
