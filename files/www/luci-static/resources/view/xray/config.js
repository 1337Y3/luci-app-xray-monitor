'use strict';
'require view';
'require rpc';
'require ui';
'require xray-diff as XrayDiff';

var callGet      = rpc.declare({ object: 'xray-monitor', method: 'config_get' });
var callTest     = rpc.declare({ object: 'xray-monitor', method: 'config_test',      params: [ 'config' ] });
var callDiffText = rpc.declare({ object: 'xray-monitor', method: 'config_diff_text', params: [ 'config' ] });
var callSave     = rpc.declare({ object: 'xray-monitor', method: 'config_save',      params: [ 'config', 'expected_hash' ] });
var callStatus   = rpc.declare({ object: 'xray-monitor', method: 'status' });

/* Baked by build-ipk.sh; compared with status.app_version in load(). LuCI
 * serves modules without a cache buster, so after an upgrade the browser
 * may still run the previous JS - the banner asks for a hard reload. */
var UI_VERSION = '__XRAY_MONITOR_VER__';
var staleUI = null;

function checkUIVersion() {
	return callStatus().then(function(s) {
		staleUI = (XrayDiff.staleVersion && s) ? XrayDiff.staleVersion(s.app_version, UI_VERSION) : null;
	}, function() {});
}

var ta = null;        // the textarea
var pathLabel = null;
var loadedHash = '';  // config_get "hash" of the bytes the editor was loaded from;
                      // sent back as expected_hash, so a config that changed on the
                      // router in the meantime refuses the save instead of clobbering

function setBusy(btns, on) { btns.forEach(function(b) { b.disabled = on; }); }

/* Parse the editor text with the same tolerance the write pipeline has: these
 * configs legally carry // and block comments (the "=== subscription: ... ==="
 * headers), and the server side reads them with ucode's json(), which also
 * accepts trailing commas. So one string-aware pass strips comments (a
 * "https://..." value must survive) and trailing commas (a "," inside a string
 * must), then JSON.parse judges the rest. Throws on invalid input. */
function parseConfigJSON(text) {
	var s = String(text), out = '', comma = -1, i = 0, n = s.length;
	while (i < n) {
		var c = s.charAt(i);
		if (c == '"') {                                  // string literal: verbatim
			var j = i + 1;
			while (j < n) {
				if (s.charAt(j) == '\\') { j += 2; continue; }
				if (s.charAt(j) == '"') break;
				j++;
			}
			out += s.substring(i, Math.min(j + 1, n));
			i = j + 1;
			comma = -1;                                  // the comma had a value
		}
		else if (c == '/' && s.charAt(i + 1) == '/') {   // line comment, keep the \n
			while (i < n && s.charAt(i) != '\n') i++;
		}
		else if (c == '/' && s.charAt(i + 1) == '*') {   // block comment
			i += 2;
			while (i < n && !(s.charAt(i) == '*' && s.charAt(i + 1) == '/')) i++;
			i += 2;
		}
		else if (c == ',') {
			out += c;
			comma = out.length - 1;                      // dropped again if only ]/} follows
			i++;
		}
		else if ((c == '}' || c == ']') && comma >= 0) {
			out = out.substring(0, comma);               // strip the trailing comma
			comma = -1;
			out += c;
			i++;
		}
		else {
			if (comma >= 0 && c != ' ' && c != '\t' && c != '\n' && c != '\r') comma = -1;
			out += c;
			i++;
		}
	}
	return JSON.parse(out);
}

/* The optimistic-locking refusal, one wording everywhere (client-side
 * pre-check in the preview and the server's conflict reply). */
function conflictMsg() {
	return _('The config changed on the router since you loaded it. Reload it from disk and re-apply your edits.');
}

/* Changed dot-paths that fall inside subscription-managed outbounds. The next
 * fetch - auto-apply especially - regenerates exactly those bodies from the
 * panel, so a hand edit there survives only until then; overrides.json is the
 * supported way to keep a per-tag tweak. Prefixes are read from the editor
 * text itself (render.uc writes each managed block under a
 * "// === subscription: <prefix> ===" header) and ownership is the same rule
 * the pipeline applies: tag == prefix or tag starts "<prefix>-". Added paths
 * index the editor's array, changed/removed the on-disk one, so both are
 * consulted; a bare "outbounds" (whole section reshaped) counts as a hit.
 * Returns the offending paths, [] when none or when nothing is managed. */
function managedChangedPaths(paths, editorText, diskText) {
	var pfx = [], m, re = /\/\/\s*===\s*subscription:\s*(.+?)\s*===/g;
	while ((m = re.exec(editorText)) !== null)
		if (m[1] && pfx.indexOf(m[1]) < 0) pfx.push(m[1]);
	if (!pfx.length) return [];
	var outs;
	try {
		outs = [ parseConfigJSON(editorText).outbounds || [], parseConfigJSON(diskText).outbounds || [] ];
	}
	catch (e) { return []; }
	var hit = [], i, j, k, pm, tag, managed;
	for (i = 0; i < (paths || []).length; i++) {
		managed = paths[i] == 'outbounds';   // the whole outbounds section
		pm = /^outbounds\.(\d+)(?:\.|$)/.exec(paths[i]);
		if (!managed && !pm) continue;
		for (k = 0; !managed && k < outs.length; k++) {
			tag = (outs[k][+pm[1]] && typeof outs[k][+pm[1]] == 'object') ? (outs[k][+pm[1]].tag || '') : '';
			for (j = 0; j < pfx.length; j++)
				if (tag == pfx[j] || tag.indexOf(pfx[j] + '-') === 0) { managed = true; break; }
		}
		if (managed) hit.push(paths[i]);
	}
	return hit;
}

function modalLine(cls, strong, text) {
	return E('p', { 'style': 'color:' + cls + ';margin:.8em 0 0;' },
		text ? [ E('strong', {}, strong), document.createTextNode(' ' + text) ] : [ E('strong', {}, strong) ]);
}

/* The subscription-management warning, amber like a "changed" path: which
 * paths are affected and what to do instead. No-op for an empty list. */
function noteManaged(notes, paths) {
	if (!paths || !paths.length) return;
	notes.push(modalLine('#cc7a00',
		_('Subscription-managed outbound(s) in this diff:'),
		_('the next fetch (auto-apply runs it by itself) rebuilds these outbounds from the panel and will revert this edit. For a permanent per-tag tweak use /etc/xray-monitor/overrides.json (see the README). Affected: ') + paths.join(', ')));
}

/* Reload the editor from disk and remember the new hash (also used after a
 * successful save: the editor then holds exactly what is installed). */
function refreshFromDisk(silent) {
	return callGet().then(function(res) {
		ta.value = (res && res.config) ? res.config : '';
		loadedHash = (res && res.hash) || '';
		if (!silent) ui.addNotification(null, E('p', _('Reloaded from disk.')), 'info');
	}, function() {
		if (!silent) ui.addNotification(null, E('p', _('Reload call failed.')), 'error');
	});
}

/* The mandatory diff preview: what saving the editor content would change,
 * semantically (dot-paths from the backend) and as a text diff. "Apply anyway"
 * continues into the locked save, "Keep editing" closes without saving. */
function showPreview(testRes, diffRes, getRes) {
	var sem  = diffRes || {};
	var cur  = (getRes && getRes.config) || '';
	var liveHash = (getRes && getRes.hash) || '';
	var conflict = !!(loadedHash && liveHash && loadedHash != liveHash);
	var badJson  = !!sem.error;
	var testBad  = !(testRes && testRes.ok);
	var nodes = [];

	if (badJson)
		nodes.push(E('p', {}, [ E('strong', {}, _('Cannot diff: ')), document.createTextNode(sem.error) ]));
	else if ((!sem.added || !sem.added.length) && (!sem.removed || !sem.removed.length) && (!sem.changed || !sem.changed.length))
		nodes.push(E('p', {}, E('em', {}, _('The editor content is semantically identical to the config on disk.'))));
	else {
		nodes.push(E('p', {}, _('Saving the editor content would change the config like this:')));
		nodes.push(XrayDiff.renderSemantic(sem));
		nodes.push(E('p', { 'style': 'margin-top:1em;' }, [
			E('strong', {}, _('Text diff (on disk → editor')), ' — ',
			_("lines marked '-' exist only in the config on disk, lines marked '+' only in the editor.")
		]));
		nodes.push(XrayDiff.renderUnified(cur, ta.value));
	}

	var notes = [];
	if (conflict) notes.push(modalLine('#cc3300', _('Not applied:'), conflictMsg()));
	if (testBad)  notes.push(modalLine('#cc3300', _('xray -test rejected the editor content:'), (testRes && testRes.msg) || _('unknown error')));
	// a hand edit inside a subscription-managed outbound is real but short-
	// lived: the next fetch (auto-apply applies it by itself) rebuilds those
	// bodies from the panel - say so here, not as a change that vanished later
	if (!badJson)
		noteManaged(notes, managedChangedPaths(
			[].concat(sem.changed || [], sem.removed || [], sem.added || []), ta.value, cur));

	var errLine = E('div', {}, notes);
	var applyBtn = E('button', { 'class': 'cbi-button cbi-button-save important' }, _('Apply anyway'));
	var keepBtn  = E('button', { 'class': 'cbi-button cbi-button-neutral' }, _('Keep editing'));
	keepBtn.addEventListener('click', ui.hideModal);
	// nothing to apply behind a conflict (the save would be refused) or behind
	// a config xray -test already rejected (the save would roll it back)
	applyBtn.disabled = conflict || testBad;

	applyBtn.addEventListener('click', function() {
		applyBtn.disabled = true;
		keepBtn.disabled = true;
		callSave(ta.value, loadedHash || '').then(function(res) {
			if (res && res.ok) {
				ui.hideModal();
				ui.addNotification(null, E('p', _('Saved and restarted xray. ') + (res.msg || '')), 'info');
				refreshFromDisk(true);
			}
			else {
				keepBtn.disabled = false;
				if (res && res.conflict) {
					errLine.appendChild(modalLine('#cc3300', _('Not applied:'), conflictMsg()));
					// Apply stays off: re-sending the stale hash can only fail again
				}
				else {
					applyBtn.disabled = false;
					errLine.appendChild(modalLine('#cc3300', _('Save failed (not applied):'), (res && res.msg) || _('unknown error')));
				}
			}
		}, function() {
			keepBtn.disabled = false;
			applyBtn.disabled = false;
			errLine.appendChild(modalLine('#cc3300', _('Save call failed.'), ''));
		});
	});

	ui.showModal(_('Save & apply: review the changes'), nodes.concat([
		errLine,
		E('div', { 'class': 'right', 'style': 'margin-top:1em;' }, [ keepBtn, applyBtn ])
	]));
}

return view.extend({
	load: function() {
		return Promise.all([ callGet().catch(function() { return {}; }), checkUIVersion() ])
			.then(function(r) { return r[0]; });
	},

	render: function(data) {
		ta = E('textarea', {
			'class': 'cbi-input-textarea',
			'style': 'width:100%;min-height:60vh;font-family:monospace;white-space:pre;overflow-wrap:normal;',
			'spellcheck': 'false', 'wrap': 'off'
		}, (data && data.config) ? data.config : '');
		loadedHash = (data && data.hash) || '';
		pathLabel = E('code', {}, (data && data.path) ? data.path : '/etc/xray/config.json');

		var testBtn   = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Test config'));
		var saveBtn   = E('button', { 'class': 'cbi-button cbi-button-save important' }, _('Save & apply'));
		var reloadBtn = E('button', { 'class': 'cbi-button cbi-button-neutral' }, _('Reload from disk'));
		var btns = [ testBtn, saveBtn, reloadBtn ];

		testBtn.addEventListener('click', function() {
			setBusy(btns, true);
			callTest(ta.value).then(function(res) {
				setBusy(btns, false);
				if (res && res.ok)
					ui.addNotification(null, E('p', _('xray -test: ') + (res.msg || 'OK')), 'info');
				else
					ui.addNotification(null, E('p', [ E('strong', {}, _('xray -test failed: ')), document.createTextNode((res && res.msg) || _('unknown error')) ]), 'error');
			}, function() { setBusy(btns, false); ui.addNotification(null, E('p', _('Test call failed.')), 'error'); });
		});

		// Saving always goes through the preview modal: the diff is computed on
		// the router against what is on disk NOW, the config must parse (with
		// the pipeline's comment tolerance) and survive xray -test before the
		// diff is even offered, and the actual save carries the hash of the
		// bytes the editor was loaded from so a concurrent change refuses it.
		saveBtn.addEventListener('click', function() {
			var perr = null;
			try { parseConfigJSON(ta.value); }
			catch (e) { perr = (e && e.message) ? e.message : _('parse error'); }
			if (perr) {
				var closeBtn = E('button', { 'class': 'cbi-button cbi-button-neutral' }, _('Keep editing'));
				closeBtn.addEventListener('click', ui.hideModal);
				ui.showModal(_('Invalid JSON'), [
					E('p', {}, [
						E('strong', {}, _('The editor content is not valid JSON (// comments are allowed): ')),
						document.createTextNode(perr)
					]),
					E('p', {}, _('Nothing was saved. Fix the syntax, then save again.')),
					E('div', { 'class': 'right' }, [ closeBtn ])
				]);
				return;
			}
			setBusy(btns, true);
			Promise.all([ callTest(ta.value), callDiffText(ta.value), callGet() ]).then(function(r) {
				setBusy(btns, false);
				// a throw inside this success handler is NOT caught by the
				// rejection handler below - without this try/catch it used to
				// vanish without a trace, leaving a button that "does nothing"
				try { showPreview(r[0], r[1], r[2]); }
				catch (e) {
					ui.addNotification(null, E('p', [
						E('strong', {}, _('Preview failed: ')),
						document.createTextNode((e && e.message) ? e.message : String(e))
					]), 'error');
				}
			}, function() {
				setBusy(btns, false);
				ui.addNotification(null, E('p', _('Preview call failed.')), 'error');
			});
		});

		reloadBtn.addEventListener('click', function() {
			setBusy(btns, true);
			refreshFromDisk(false).then(function() { setBusy(btns, false); });
		});

		var nodes = [
			E('h2', {}, _('Xray Config')),
			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, [ _('Editing '), pathLabel, _('. '),
					E('strong', {}, _('Test config')), _(' runs xray -test on the editor contents without saving. '),
					E('strong', {}, _('Save & apply')), _(' first shows a preview of what would change (semantic + text diff); "Apply anyway" then validates, backs up (config.json.bak.manual.*), writes, and restarts xray — and rolls back automatically if the test fails. If the config changed on the router after this page loaded it, the save is refused and you must reload it and re-apply your edits. '),
					_('Edits inside a "// === subscription: <prefix> ===" block are reverted by the next fetch — auto-apply runs it by itself; keep per-tag tweaks in /etc/xray-monitor/overrides.json instead.') ]),
				ta,
				E('div', { 'style': 'margin-top:.6em;display:flex;gap:8px;' }, [ testBtn, saveBtn, reloadBtn ])
			])
		];
		if (staleUI) nodes.unshift(staleUI);
		return E('div', {}, nodes);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
