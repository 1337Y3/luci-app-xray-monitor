'use strict';
/* JS regression guards for the LuCI client side (run by tests/js-test.sh in
 * CI; needs only node). The 475d8a1 lesson: an unclosed block comment that
 * swallows a var definition is still perfectly valid syntax, so a syntax
 * pass alone cannot catch it - the module must be EXECUTED. xray-diff.js is
 * loaded here with baseclass/E/_/document stubs (the contract luci.js
 * provides) and its diff paths are run; every view/*.js is additionally
 * compiled through new Function (a view's top-level `return` is illegal as a
 * script but fine in a function body, which is how LuCI evaluates modules). */

const fs = require('fs');
const path = require('path');

const root = path.resolve(process.argv[2] || path.join(__dirname, '..', '..'));
const resDir = path.join(root, 'files', 'www', 'luci-static', 'resources');
const viewDir = path.join(resDir, 'view', 'xray');
let failed = 0;

function ok(cond, label) {
	console.log((cond ? 'PASS ' : 'FAIL ') + label);
	if (!cond) failed++;
}

/* ---- every view + the shared module must at least compile ---- */
for (const f of fs.readdirSync(viewDir).filter(n => n.endsWith('.js')).sort()) {
	const src = fs.readFileSync(path.join(viewDir, f), 'utf8');
	let err = null;
	try { new Function(src); } catch (e) { err = e; }
	ok(!err, 'syntax view/' + f + (err ? ' (' + err.message + ')' : ''));
}
{
	const src = fs.readFileSync(path.join(resDir, 'xray-diff.js'), 'utf8');
	let err = null;
	try { new Function('baseclass', '_', 'E', 'document', src); } catch (e) { err = e; }
	ok(!err, 'syntax xray-diff.js' + (err ? ' (' + err.message + ')' : ''));
}

/* ---- functional: execute xray-diff.js with luci.js-shaped stubs ---- */
const baseclass = { extend: function (o) { return o; } };
const _ = function (s) { return s; };
function E(tag, attrs, children) {
	return {
		tag: tag,
		attrs: attrs || {},
		children: [].concat(children || []).filter(function (c) { return c !== null && c !== undefined; }),
		appendChild: function (c) { this.children.push(c); }
	};
}
const documentStub = { createTextNode: function (t) { return { text: t }; } };

const src = fs.readFileSync(path.join(resDir, 'xray-diff.js'), 'utf8');
const XrayDiff = new Function('baseclass', '_', 'E', 'document', src)(baseclass, _, E, documentStub);

ok(typeof XrayDiff.unifiedDiff === 'function'
	&& typeof XrayDiff.renderUnified === 'function'
	&& typeof XrayDiff.renderSemantic === 'function'
	&& typeof XrayDiff.staleVersion === 'function', 'module exports all four functions');

/* the git copy must keep the placeholder - a baked version here means a
 * packaged file leaked back into the repository */
ok(XrayDiff.version === '__XRAY_MONITOR_VER__', 'UI_VERSION placeholder intact in git');

/* a one-line replacement through the Myers path: throws ReferenceError if a
 * comment ever swallows a definition again (the 475d8a1 regression) */
const ops = XrayDiff.unifiedDiff('alpha\nbeta\ngamma\n', 'alpha\nBETA\ngamma\n');
const dels = ops.filter(function (o) { return o.t === '-'; }),
      adds = ops.filter(function (o) { return o.t === '+'; });
ok(ops.length === 4 && dels.length === 1 && dels[0].s === 'beta'
	&& adds.length === 1 && adds[0].s === 'BETA'
	&& ops[0].t === '=' && ops[0].s === 'alpha' && ops[3].s === 'gamma',
	'unifiedDiff: one-line replacement');

/* identical inputs short-circuit before Myers */
ok(XrayDiff.unifiedDiff('a\nb\n', 'a\nb\n').every(function (o) { return o.t === '='; }),
	'unifiedDiff: identical inputs');

const box = XrayDiff.renderUnified('a\nb\nc', 'a\nx\nc');
ok(!!box && box.tag === 'div' && box.children.length > 0, 'renderUnified: differing texts render');

const same = XrayDiff.renderUnified('a\n', 'a\n');
ok(JSON.stringify(same).indexOf('No differences') >= 0, 'renderUnified: identical -> No differences');

const tbl = XrayDiff.renderSemantic({ added: ['x.a'], removed: [], changed: ['y.b'] });
ok(tbl.tag === 'table' && tbl.children.length === 3, 'renderSemantic: three category rows');

ok(XrayDiff.staleVersion('1.22-2', '1.22-2') === null, 'staleVersion: match -> null');
ok(XrayDiff.staleVersion(undefined, '1.22-2') === null, 'staleVersion: no status -> null');
ok(XrayDiff.staleVersion('1.22-2', '__XRAY_MONITOR_VER__') === null, 'staleVersion: unbaked -> null');
const banner = XrayDiff.staleVersion('1.22-3', '1.22-2');
ok(!!banner && banner.tag === 'div' && JSON.stringify(banner).indexOf('Ctrl+Shift+R') >= 0,
	'staleVersion: mismatch -> reload banner');

if (failed) {
	console.error(failed + ' check(s) failed');
	process.exit(1);
}
console.log('all JS checks passed');
