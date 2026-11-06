// Shared renderer for a config's `outbounds` section. ucode's %.2J round-trip
// drops the // block comments, so every writer that re-emits config.json
// (apply.uc, routing.uc, balancers.uc) rebuilds the section through here and
// keeps the same layout: one `// === subscription: <prefix> ===` block per
// subscription, then a `// === local ===` block for everything not owned by a
// subscription (direct/freedom, balancers, hand-added proxies). Imported as a
// module by the scripts in this directory; not a standalone command (so no
// shebang either - the module compiler rejects `#`).
'use strict';
import { writefile } from 'fs';

let proxy_protos = [ 'vless', 'vmess', 'trojan', 'shadowsocks' ];

function indent(s, pad) {
	let lines = split(s, "\n"), out = [];
	for (let i = 0; i < length(lines); i++) push(out, pad + lines[i]);
	return join("\n", out);
}

// groups: [ { label, outbounds: [...] }, ... ]  (empty groups are skipped)
// locals: [ outbound, ... ]
function render_outbounds(groups, locals) {
	let parts = [];
	for (let g = 0; g < length(groups); g++) {
		let grp = groups[g], obs = grp.outbounds ?? [];
		if (!length(obs)) continue;
		push(parts, "    // === subscription: " + ((grp.label && length(grp.label)) ? grp.label : "(default)") + " ===");
		for (let i = 0; i < length(obs); i++)
			push(parts, indent(sprintf('%.2J', obs[i]), "    "));
	}
	if (length(locals)) {
		push(parts, "    // === local ===");
		for (let i = 0; i < length(locals); i++)
			push(parts, indent(sprintf('%.2J', locals[i]), "    "));
	}
	return "[\n" + join(",\n", parts) + "\n  ]";
}

// Serialize the whole config with the outbounds array from render_outbounds().
// The placeholder keeps %.2J from escaping the hand-built section; the marker
// cannot occur in a real config value position.
function render_config(cfg, groups, locals) {
	cfg.outbounds = "__OB__";
	let full = sprintf('%.2J', cfg);
	return replace(full, '"outbounds": "__OB__"', '"outbounds": ' + render_outbounds(groups, locals));
}

// The subscription prefix that OWNS a tag: the tag equals the prefix or starts
// with "<prefix>-". Prefixes may nest ("proxy" and "proxy-work" are both legal
// subscriptions), so on overlap the LONGEST match owns the tag - "proxy-work-fi"
// belongs to "proxy-work", never to "proxy". First-match-wins (the old rule)
// made ownership depend on argument order and let a failed "proxy" fetch
// snapshot another subscription's exits, producing duplicate outbound tags.
// Returns null when no prefix owns the tag.
function owner_prefix(tag, prefixes) {
	if (tag == null) tag = '';
	let owner = null;
	for (let i = 0; i < length(prefixes); i++) {
		let p = prefixes[i];
		if (tag == p || substr(tag, 0, length(p) + 1) == p + '-') {
			if (owner == null || length(p) > length(owner)) owner = p;
		}
	}
	return owner;
}

// Group an existing config's outbounds for re-emission by writers that do not
// touch outbounds themselves (routing/balancers): each proxy outbound goes to
// the group of the prefix that owns it (longest match, config order preserved),
// the rest to locals. Without prefixes every outbound is local.
function split_outbounds(cfg, prefixes) {
	let groups = [], by_label = {};
	for (let i = 0; i < length(prefixes); i++) {
		let grp = { label: prefixes[i], outbounds: [] };
		push(groups, grp);
		by_label[prefixes[i]] = grp;
	}
	let locals = [], obs = cfg.outbounds ?? [];
	for (let i = 0; i < length(obs); i++) {
		let owner = (obs[i].protocol in proxy_protos) ? owner_prefix(obs[i].tag, prefixes) : null;
		if (owner != null && exists(by_label, owner)) push(by_label[owner].outbounds, obs[i]);
		else push(locals, obs[i]);
	}
	return { groups: groups, locals: locals };
}

// Convenience for the set-style writers: render to out_path (atomic copy is the
// caller's job) or to stdout.
function emit(cfg, groups, locals, out_path) {
	if (out_path) { writefile(out_path, render_config(cfg, groups, locals)); printf('OK\n'); }
	else printf('%s\n', render_config(cfg, groups, locals));
}

export { render_outbounds, render_config, split_outbounds, owner_prefix, emit };
