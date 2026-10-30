'use strict';
/* Xray Monitor diff helpers, shared by the views (Backups tab today).
 * Loaded with 'require xray-diff'. Two independent pieces:
 *  - a line-based unified diff (Myers O(ND) greedy algorithm, common
 *    prefix/suffix trim, bounded cost with a plain-replace fallback) rendered
 *    as colored hunks in a <pre>-style block
 *  - a renderer for the semantic (JSON dot-path) diff produced by the rpcd
 *    config_diff method (jsondiff.uc paths_diff)
 * No dependencies besides the luci-base globals E() and _(). */

var MAX_COST = 1024;   /* Myers edit-distance cap per input pair; beyond it the
                          fallback emits one delete+add block for the whole
                          differing middle (correct, just not minimal), so the
                          O(cost^2) snapshot memory/time stays bounded. Config
                          files are ~2000 lines with small localized edits, so
                          the real cost after prefix/suffix trimming is tiny
                          and the fallback stays a pathological-input guard. */
var CONTEXT = 3;       /* context lines kept around each hunk */

function splitLines(text) {
	if (text === null || typeof text == 'undefined' || text === '') return [];
	var lines = String(text).split('\n');
	if (lines.length && lines[lines.length - 1] === '') lines.pop();   /* trailing \n */
	return lines;
}

/* Greedy Myers diff over two line arrays -> [{ t: '='|'-'|'+', s: line }]
 * covering both inputs in order, or null when the edit distance exceeds
 * MAX_COST. Classic forward pass storing a V-vector snapshot per step so the
 * path can be backtracked. */
function myers(a, b) {
	var n = a.length, m = b.length;
	if (n === 0 && m === 0) return [];
	var v = { 1: 0 }, trace = [], ops = [];
	var d, k, x, y;

	outer:
	for (d = 0; d <= n + m; d++) {
		if (d > MAX_COST) return null;
		for (k = -d; k <= d; k += 2) {
			if (k == -d || (k != d && gv(v, k - 1) < gv(v, k + 1))) x = gv(v, k + 1);
			else x = gv(v, k - 1) + 1;
			y = x - k;
			while (x < n && y < m && a[x] === b[y]) { x++; y++; }
			v[k] = x;
			if (x >= n && y >= m) { trace.push(snap(v)); break outer; }
		}
		trace.push(snap(v));
	}

	/* backtrack from (n, m) using the snapshot taken before each step */
	x = n; y = m;
	for (d = trace.length - 1; d > 0; d--) {
		v = trace[d - 1];
		k = x - y;
		var pk = (k == -d || (k != d && gv(v, k - 1) < gv(v, k + 1))) ? k + 1 : k - 1;
		var px = gv(v, pk), py = px - pk;
		while (x > px && y > py) { ops.push({ t: '=', s: a[x - 1] }); x--; y--; }
		if (x == px) { ops.push({ t: '+', s: b[y - 1] }); y--; }
		else         { ops.push({ t: '-', s: a[x - 1] }); x--; }
	}
	while (x > 0 && y > 0) { ops.push({ t: '=', s: a[x - 1] }); x--; y--; }
	ops.reverse();
	return ops;
}

/* V-vector accessors: keys outside the current d are absent (treated as -1) */
function gv(v, k) { return (typeof v[k] != 'undefined') ? v[k] : -1; }
function snap(v) { var c = {}, k; for (k in v) c[k] = v[k]; return c; }

/* Line diff of two texts with common prefix/suffix trimmed first; never
 * returns null (falls back to a full replace of the differing middle). */
function unifiedDiff(aText, bText) {
	var a = splitLines(aText), b = splitLines(bText);
	var p = 0;
	while (p < a.length && p < b.length && a[p] === b[p]) p++;
	var s = 0;
	while (s < a.length - p && s < b.length - p && a[a.length - 1 - s] === b[b.length - 1 - s]) s++;

	var mid = myers(a.slice(p, a.length - s), b.slice(p, b.length - s)), i;
	if (mid === null) {
		mid = [];
		for (i = p; i < a.length - s; i++) mid.push({ t: '-', s: a[i] });
		for (i = p; i < b.length - s; i++) mid.push({ t: '+', s: b[i] });
	}

	var ops = [];
	for (i = 0; i < p; i++) ops.push({ t: '=', s: a[i] });
	ops = ops.concat(mid);
	for (i = a.length - s; i < a.length; i++) ops.push({ t: '=', s: a[i] });
	return ops;
}

/* Render a unified diff of the two texts: hunks with @@ headers, '-' lines
 * red (from aText = "old"), '+' lines green (from bText = "new"). */
function renderUnified(aText, bText) {
	var ops = unifiedDiff(aText, bText);

	/* group change runs into hunks separated by more than 2*CONTEXT equals */
	var groups = [], i, j;
	for (i = 0; i < ops.length; i++) {
		if (ops[i].t == '=') continue;
		if (groups.length && i - groups[groups.length - 1].last <= 2 * CONTEXT)
			groups[groups.length - 1].last = i;
		else
			groups.push({ first: i, last: i });
	}

	var box = E('div', {
		'style': 'border:1px solid rgba(128,128,128,.3);border-radius:4px;overflow-x:auto;max-height:50vh;font-family:monospace;font-size:12px;line-height:1.6;'
	});

	if (!groups.length) {
		box.appendChild(E('div', { 'style': 'padding:4px 8px;color:#888;' }, _('No differences')));
		return box;
	}

	/* mark which op indices are visible (inside a hunk window) */
	var vis = [], q;
	for (q = 0; q < ops.length; q++) vis[q] = false;
	for (j = 0; j < groups.length; j++)
		for (i = Math.max(0, groups[j].first - CONTEXT); i <= Math.min(ops.length - 1, groups[j].last + CONTEXT); i++)
			vis[i] = true;

	var aNo = 1, bNo = 1, inHunk = false, a0 = 1, b0 = 1, nA = 0, nB = 0, hdr = null;
	for (i = 0; i < ops.length; i++) {
		var t = ops[i].t;
		if (vis[i] && !inHunk) {
			inHunk = true; a0 = aNo; b0 = bNo; nA = 0; nB = 0;
			hdr = E('div', { 'style': 'color:#888;background:rgba(128,128,128,.08);padding:0 8px;' }, '');
			box.appendChild(hdr);
		}
		if (inHunk && t != '+') nA++;
		if (inHunk && t != '-') nB++;
		if (inHunk) {
			var style = 'padding:0 8px;white-space:pre;';
			var mark;
			if (t == '-') { mark = E('span', { 'style': 'color:#cc3300;' }, '-'); style += 'background:rgba(204,51,0,.13);'; }
			else if (t == '+') { mark = E('span', { 'style': 'color:#46a546;' }, '+'); style += 'background:rgba(70,165,70,.13);'; }
			else { mark = E('span', { 'style': 'color:#888;' }, ' '); }
			box.appendChild(E('div', { 'style': style }, [mark, document.createTextNode(ops[i].s === '' ? ' ' : ops[i].s)]));
		}
		if (t != '+') aNo++;
		if (t != '-') bNo++;
		if (inHunk && (i == ops.length - 1 || !vis[i + 1])) {
			hdr.appendChild(document.createTextNode('@@ -' + a0 + ',' + nA + ' +' + b0 + ',' + nB + ' @@'));
			inHunk = false;
		}
	}
	return box;
}

/* Render a semantic paths_diff object ({added,removed,changed} of dot.paths,
 * as returned by the config_diff rpcd method) as a table with one row per
 * category. Generic labels: the caller frames the direction ("current vs
 * backup") around it. */
function renderSemantic(diff) {
	var d = diff || {};
	var cats = [
		{ label: _('Added'),   paths: d.added   || [], color: '#46a546' },
		{ label: _('Removed'), paths: d.removed || [], color: '#cc3300' },
		{ label: _('Changed'), paths: d.changed || [], color: '#cc7a00' }
	];
	var rows = [];
	var i, j, spans;
	for (i = 0; i < cats.length; i++) {
		spans = [];
		for (j = 0; j < cats[i].paths.length; j++)
			spans.push(E('span', {
				'style': 'font-family:monospace;font-size:90%;color:' + cats[i].color +
					';background:rgba(128,128,128,.08);border-radius:3px;padding:0 4px;margin:2px 6px 2px 0;display:inline-block;word-break:break-all;'
			}, String(cats[i].paths[j])));
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'style': 'width:18%;white-space:nowrap;' },
				E('strong', { 'style': 'color:' + cats[i].color + ';' }, cats[i].label)),
			E('td', { 'class': 'td' }, spans.length ? spans : E('em', { 'style': 'color:#888;' }, _('none')))
		]));
	}
	return E('table', { 'class': 'table' }, rows);
}

return {
	unifiedDiff: unifiedDiff,
	renderUnified: renderUnified,
	renderSemantic: renderSemantic
};
