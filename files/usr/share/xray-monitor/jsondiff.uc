// Shared structural JSON diff, imported by diff.uc (canonsig) and by
// jsondiff-cli.uc (paths_diff, which the rpcd config_diff method calls).
//
// Module API:
//   deep_copy(v)     fully independent copy of a JSON value (objects/arrays
//                    cloned recursively) - lets callers prune ignored dot-paths
//                    out of a value without corrupting the parsed document it
//                    came from
//   canonsig(v)      canonical order-independent serialization (object keys
//                    sorted, values recursive) - two values that differ only
//                    in object key order serialize identically
//   paths_diff(a, b) -> { added: [dot.path], removed: [dot.path], changed: [dot.path] }
//                    added   = paths present in b but not in a
//                    removed = paths present in a but not in b
//                    changed = leaf paths whose values differ (a type change
//                              at some path counts as a change of that path;
//                              there is no recursion past it)
//                    Paths are dot.notated; array elements appear by index
//                    (a.b.0.c). Array order is significant (unlike object key
//                    order). A change of the whole document shows as the empty
//                    path "".
//
// This file is a module only: ucode's `export` statement is module-only
// syntax, so the same file cannot also run as a main script - the CLI entry
// point is jsondiff-cli.uc next to it.
'use strict';

// Canonical, order-independent serialization: object keys are sorted, so a mere
// reordering of fields in the panel output does not read as a change.
function canonsig(v) {
	if (type(v) == 'object') {
		let ks = sort(keys(v)), parts = [];
		for (let i = 0; i < length(ks); i++) push(parts, ks[i] + ':' + canonsig(v[ks[i]]));
		return '{' + join(',', parts) + '}';
	}
	if (type(v) == 'array') {
		let parts = [];
		for (let i = 0; i < length(v); i++) push(parts, canonsig(v[i]));
		return '[' + join(',', parts) + ']';
	}
	return sprintf('%J', v);
}

// Fully independent copy: every nested object/array is cloned, so mutating the
// copy (prune below, in the importers) never touches the original document.
function deep_copy(v) {
	if (type(v) == 'object') {
		let c = {};
		for (let k in v) c[k] = deep_copy(v[k]);
		return c;
	}
	if (type(v) == 'array') {
		let a = [];
		for (let i = 0; i < length(v); i++) push(a, deep_copy(v[i]));
		return a;
	}
	return v;
}

// Depth-first walk of the two trees. canonsig equality at every level makes
// equal-but-reordered subtrees cheap to skip; only genuinely differing objects
// and arrays are descended into.
function walk(a, b, path, res) {
	if (canonsig(a) == canonsig(b)) return;
	let ta = type(a), tb = type(b);
	if (ta != tb || (ta != 'object' && ta != 'array')) {
		push(res.changed, path);
		return;
	}
	if (ta == 'object') {
		let p;
		for (let k in b) {
			p = length(path) ? path + '.' + k : k;
			if (!exists(a, k)) push(res.added, p);
			else walk(a[k], b[k], p, res);
		}
		for (let k in a) {
			if (!exists(b, k)) push(res.removed, length(path) ? path + '.' + k : k);
		}
	}
	else {
		let n = (length(a) < length(b)) ? length(a) : length(b);
		for (let i = 0; i < n; i++) walk(a[i], b[i], path + '.' + i, res);
		for (let i = n; i < length(b); i++) push(res.added, path + '.' + i);
		for (let i = n; i < length(a); i++) push(res.removed, path + '.' + i);
	}
}

function paths_diff(a, b) {
	let res = { added: [], removed: [], changed: [] };
	walk(a ?? {}, b ?? {}, '', res);
	return res;
}

export { canonsig, deep_copy, paths_diff };
