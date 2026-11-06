'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require xray-diff as XrayDiff';

var callGet = rpc.declare({ object: 'xray-monitor', method: 'balancers_get' });
var callSet = rpc.declare({ object: 'xray-monitor', method: 'balancers_set', params: [ 'balancers' ] });
var callLive = rpc.declare({ object: 'xray-monitor', method: 'balancers_live' });
var callOvSet = rpc.declare({ object: 'xray-monitor', method: 'balancer_override_set', params: [ 'balancer', 'outbound' ] });
var callOvDel = rpc.declare({ object: 'xray-monitor', method: 'balancer_override_del', params: [ 'balancer' ] });
var callOvApply = rpc.declare({ object: 'xray-monitor', method: 'balancer_override_apply' });
var callStatus = rpc.declare({ object: 'xray-monitor', method: 'status' });

/* Baked by build-common.sh; compared with status.app_version in load(). LuCI
 * serves modules without a cache buster, so after an upgrade the browser
 * may still run the previous JS - the banner asks for a hard reload. */
var UI_VERSION = '__XRAY_MONITOR_VER__';
var staleUI = null;

function checkUIVersion() {
	return callStatus().then(function(s) {
		staleUI = (XrayDiff.staleVersion && s) ? XrayDiff.staleVersion(s.app_version, UI_VERSION) : null;
	}, function() {});
}

var STRATEGIES = [ 'leastPing', 'leastLoad', 'roundRobin', 'random' ];

var root = null;           // config editor section (rebuilt on load/save only)
var liveRoot = null;       // live state section (rebuilt on every poll tick)
var outbounds = [];        // [tag] from the saved config
var working = [];          // [{tag, selector:[], strategy, fallbackTag}]
var rowEls = [];           // [{tag, strategy, fallback, members:{tag:checkbox}}]
var liveData = null;       // last balancers_live reply
var liveChoice = {};       // balancer tag -> dropdown value the user picked

function syncFromInputs() {
	for (var i = 0; i < rowEls.length && i < working.length; i++) {
		var el = rowEls[i];
		working[i].tag = el.tag.value.trim();
		working[i].strategy = el.strategy.value;
		working[i].fallbackTag = el.fallback.value;
		var sel = [];
		for (var t in el.members) if (el.members[t].checked) sel.push(t);
		working[i].selector = sel;
	}
}

function mkSelect(options, sel, withNone) {
	var opts = [];
	if (withNone) opts.push(E('option', { 'value': '', 'selected': (!sel) ? '' : null }, '— none —'));
	options.forEach(function(o) {
		opts.push(E('option', { 'value': o, 'selected': (o == sel) ? '' : null }, o));
	});
	return E('select', { 'class': 'cbi-input-select' }, opts);
}

function buildCard(row, idx) {
	var tagI = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:180px', 'value': row.tag });
	var strat = mkSelect(STRATEGIES, row.strategy, false);
	var fb = mkSelect(outbounds, row.fallbackTag, true);
	var del = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('Delete balancer'));
	del.addEventListener('click', function() { syncFromInputs(); working.splice(idx, 1); redraw(); });

	var members = {};
	var memberBoxes = outbounds.map(function(t) {
		var cb = E('input', { 'type': 'checkbox', 'checked': (row.selector.indexOf(t) >= 0) ? '' : null });
		members[t] = cb;
		return E('label', { 'style': 'display:inline-flex;align-items:center;gap:4px;margin:2px 10px 2px 0;' }, [ cb, E('span', {}, t) ]);
	});

	rowEls.push({ tag: tagI, strategy: strat, fallback: fb, members: members });

	function field(label, el) {
		return E('div', { 'style': 'margin:4px 0;' }, [
			E('span', { 'style': 'display:inline-block;width:130px;color:#666;' }, label), el
		]);
	}

	return E('div', { 'style': 'border:1px solid rgba(128,128,128,.3);border-radius:6px;padding:10px;margin:8px 0;' }, [
		E('div', { 'style': 'display:flex;justify-content:space-between;align-items:center;' }, [
			E('strong', {}, _('Balancer')), del
		]),
		field(_('Tag'), tagI),
		field(_('Strategy'), strat),
		field(_('Fallback'), fb),
		E('div', { 'style': 'margin:6px 0;' }, [
			E('div', { 'style': 'color:#666;margin-bottom:2px;' }, _('Members (outbounds to combine)')),
			E('div', {}, memberBoxes)
		])
	]);
}

function redraw() {
	rowEls = [];
	var cards = working.map(buildCard);
	if (!working.length) cards = [ E('em', {}, _('No balancers. Add one below.')) ];

	var addBtn = E('button', { 'class': 'cbi-button cbi-button-add' }, _('+ Add balancer'));
	addBtn.addEventListener('click', function() {
		syncFromInputs();
		working.push({ tag: '', selector: [], strategy: 'leastPing', fallbackTag: '' });
		redraw();
	});
	var saveBtn = E('button', { 'class': 'cbi-button cbi-button-save important' }, _('Save & apply'));
	saveBtn.addEventListener('click', function() { doSave(saveBtn); });

	var content = [
		E('h3', {}, _('Outbound balancers')),
		E('div', {}, cards),
		E('div', { 'style': 'margin:.6em 0;display:flex;gap:8px;' }, [ addBtn, saveBtn ]),
		E('div', { 'style': 'color:#888;font-size:90%;' }, [
			E('p', {}, _('A balancer combines several outbounds; route an inbound to it from the Routing tab (it appears as an exit). leastPing/leastLoad pick the best member by latency/load — those members are auto-probed via the observatory. random/roundRobin need no probing.')),
			E('p', {}, _('Save validates with xray -test, backs up config.json, and restarts xray (auto-rollback on failure). Deleting a balancer still referenced by a routing rule will fail the test and roll back.'))
		])
	];

	while (root.firstChild) root.removeChild(root.firstChild);
	content.forEach(function(n) { root.appendChild(n); });
}

function doSave(btn) {
	syncFromInputs();
	var seen = {}, obSet = {};
	outbounds.forEach(function(t) { obSet[t] = 1; });
	for (var i = 0; i < working.length; i++) {
		var b = working[i];
		if (!/^[A-Za-z0-9_.\-]+$/.test(b.tag))
			return ui.addNotification(null, E('p', _('Invalid balancer tag: ') + (b.tag || '(empty)')), 'error');
		if (obSet[b.tag])
			return ui.addNotification(null, E('p', _('Balancer tag must differ from an outbound tag: ') + b.tag), 'error');
		if (seen[b.tag]) return ui.addNotification(null, E('p', _('Duplicate balancer tag: ') + b.tag), 'error');
		seen[b.tag] = 1;
		if (!b.selector.length)
			return ui.addNotification(null, E('p', _('Balancer "') + b.tag + _('" needs at least one member')), 'error');
	}
	if (!confirm(_('Apply balancer changes and restart xray now?'))) return;
	btn.disabled = true;
	callSet(working).then(function(res) {
		btn.disabled = false;
		if (res && res.ok) { ui.addNotification(null, E('p', _('Balancers applied and xray restarted.')), 'info'); return refresh(); }
		ui.addNotification(null, E('p', _('Apply failed — config not changed. ') + ((res && res.msg) || '')), 'error');
	}, function() { btn.disabled = false; ui.addNotification(null, E('p', _('Apply call failed.')), 'error'); });
}

// --- live state + sticky overrides (F15) -------------------------------------

function stateLabel(b) {
	// divergence between the saved pin (UCI) and the one active on the
	// running xray (bi) - computed server-side, only worded here
	if (b.state == 'missing')
		return { text: _('Saved pin is not active on the running xray (external restart?)'), cls: 'warn' };
	if (b.state == 'drift')
		return { text: _('Active pin differs from the saved pin'), cls: 'warn' };
	if (b.state == 'unexpected')
		return { text: _('Active pin is not saved here'), cls: 'warn' };
	return { text: b.overrideUci ? _('Saved pin active') : _('No pin'), cls: 'ok' };
}

function livePickText(b) {
	if (!b.live) return E('em', {}, _('unreachable'));
	if (b.overrideLive)
		return E('strong', {}, b.overrideLive + '  (' + _('pinned') + ')');
	if (b.pick) return E('strong', {}, b.pick);
	if (b.targets && b.targets.length) {
		// random/roundRobin pick per connection - only the candidate set is
		// knowable from outside
		return E('span', {}, _('any of: ') + b.targets.join(', '));
	}
	return E('em', {}, _('no nodes'));
}

function liveRow(b) {
	var st = stateLabel(b);
	var stEl = E('span', { 'style': (st.cls == 'warn') ? 'color:#c05000;' : 'color:#3d8b40;' }, st.text);

	// pin control: dropdown of every outbound of the saved config; the
	// preselection survives the 10 s redraw via liveChoice
	var sel = (liveChoice[b.tag] !== undefined) ? liveChoice[b.tag]
		: (b.overrideUci || b.overrideLive || '');
	var dd = mkSelect(outbounds, sel, true);
	dd.addEventListener('change', function() { liveChoice[b.tag] = dd.value; });

	var pinBtn = E('button', { 'class': 'cbi-button cbi-button-add', 'style': 'margin-left:6px;' }, _('Pin'));
	pinBtn.disabled = !dd.value;
	dd.addEventListener('change', function() { pinBtn.disabled = !dd.value; });
	pinBtn.addEventListener('click', function() { doPin(pinBtn, b.tag, dd.value); });

	var row = E('div', { 'style': 'display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:4px 0;border-bottom:1px solid rgba(128,128,128,.15);' }, [
		E('strong', { 'style': 'min-width:120px;' }, b.tag),
		E('span', { 'style': 'color:#888;min-width:90px;' }, b.strategy),
		E('span', { 'style': 'min-width:180px;' }, [ E('span', { 'style': 'color:#888;margin-right:4px;' }, _('using')), livePickText(b) ]),
		E('span', { 'style': 'flex:1;' }, stEl)
	]);
	var hasPin = !!(b.overrideUci || b.overrideLive);
	if (hasPin) {
		var unBtn = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('Unpin'));
		unBtn.addEventListener('click', function() { doUnpin(unBtn, b.tag); });
		row.appendChild(unBtn);
	}
	row.appendChild(E('span', { 'style': 'display:inline-flex;align-items:center;' }, [ dd, pinBtn ]));
	return row;
}

function redrawLive() {
	if (!liveRoot) return;
	var nodes = [];
	var bal = (liveData && liveData.balancers) || [];
	var stale = (liveData && liveData.stale) || [];
	var anyPin = bal.some(function(b) { return !!b.overrideUci; }) || stale.length > 0;
	var divergent = bal.filter(function(b) { return b.state != 'ok'; });

	nodes.push(E('h3', {}, _('Live state')));

	if (!bal.length && !stale.length) {
		nodes.push(E('p', { 'style': 'color:#888;' }, _('No balancers in the saved config - add one below.')));
	} else {
		if (liveData && liveData.api === false)
			nodes.push(E('p', { 'style': 'color:#c05000;' },
				_('The Xray Routing API did not answer (xray down or API services not enabled on the Overview tab) - showing saved pins only.')));

		if (divergent.length) {
			var why = {};
			divergent.forEach(function(b) { why[b.state] = 1; });
			var hint = '';
			if (why.missing) hint = _('xray was restarted outside this app - the saved pins were wiped from its memory.');
			else if (why.drift) hint = _('someone pinned from outside this app (CLI)');
			else hint = _('an override is active that this app did not save');
			nodes.push(E('p', { 'style': 'padding:6px 10px;border:1px solid #c05000;border-radius:6px;color:#c05000;' }, [
				E('strong', {}, _('Pins out of sync: ')), hint + ' ',
				E('em', {}, _('Use "Re-apply overrides" to restore the saved pins.'))
			]));
		}

		var head = E('div', { 'style': 'display:flex;align-items:center;gap:8px;padding:4px 0;color:#666;' }, [
			E('span', { 'style': 'min-width:120px;' }, _('Balancer')),
			E('span', { 'style': 'min-width:90px;' }, _('Strategy')),
			E('span', { 'style': 'min-width:180px;' }, _('Currently using')),
			E('span', { 'style': 'flex:1;' }, _('Sticky pin'))
		]);
		nodes.push(E('div', {}, [ head ].concat(bal.map(liveRow))));
		if (stale.length) {
			var rows = stale.map(function(s) {
				var delBtn = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('Remove'));
				delBtn.addEventListener('click', function() { doUnpin(delBtn, s.balancer); });
				return E('div', { 'style': 'display:flex;align-items:center;gap:8px;padding:4px 0;' }, [
					E('span', {}, _('Saved pin for a balancer that no longer exists: ')),
					E('strong', {}, s.balancer + ' → ' + s.outbound), delBtn
				]);
			});
			nodes.push(E('div', { 'style': 'margin-top:6px;' }, rows));
		}
	}

	var applyBtn = E('button', { 'class': 'cbi-button cbi-button-apply' }, _('Re-apply overrides'));
	applyBtn.style.display = anyPin ? '' : 'none';
	applyBtn.addEventListener('click', function() { doApplyAll(applyBtn); });
	nodes.push(E('div', { 'style': 'margin:8px 0;display:flex;gap:8px;' }, [
		applyBtn,
		E('span', { 'style': 'color:#888;font-size:90%;align-self:center;' },
			_('A pin forces the balancer onto one outbound immediately (no restart). Pins live in the running xray only; the saved pins are re-applied after every restart.'))
	]));

	while (liveRoot.firstChild) liveRoot.removeChild(liveRoot.firstChild);
	nodes.forEach(function(n) { liveRoot.appendChild(n); });
}

function doPin(btn, bal, outbound) {
	if (!confirm(_('Pin balancer "%s" to outbound "%s" now? This redirects its traffic immediately.').replace('%s', bal).replace('%s', outbound))) return;
	btn.disabled = true;
	callOvSet(bal, outbound).then(function(res) {
		btn.disabled = false;
		delete liveChoice[bal];
		if (res && res.ok) { ui.addNotification(null, E('p', res.msg || _('Pinned.')), 'info'); return refreshLive(); }
		ui.addNotification(null, E('p', _('Pin failed. ') + ((res && res.msg) || '')), 'error');
		refreshLive();
	}, function() { btn.disabled = false; ui.addNotification(null, E('p', _('Pin call failed.')), 'error'); });
}

function doUnpin(btn, bal) {
	if (!confirm(_('Remove the sticky pin from balancer "%s"? The strategy picks again on its own.').replace('%s', bal))) return;
	btn.disabled = true;
	callOvDel(bal).then(function(res) {
		btn.disabled = false;
		delete liveChoice[bal];
		if (res && res.ok) { ui.addNotification(null, E('p', res.msg || _('Unpinned.')), 'info'); return refreshLive(); }
		ui.addNotification(null, E('p', _('Unpin failed. ') + ((res && res.msg) || '')), 'error');
		refreshLive();
	}, function() { btn.disabled = false; ui.addNotification(null, E('p', _('Unpin call failed.')), 'error'); });
}

function doApplyAll(btn) {
	if (!confirm(_('Re-apply every saved pin to the running xray now?'))) return;
	btn.disabled = true;
	callOvApply().then(function(res) {
		btn.disabled = false;
		if (res && res.ok) { ui.addNotification(null, E('p', _('Overrides re-applied.')), 'info'); return refreshLive(); }
		ui.addNotification(null, E('p', _('Re-apply failed. ') + ((res && res.msg) || '')), 'error');
	}, function() { btn.disabled = false; ui.addNotification(null, E('p', _('Re-apply call failed.')), 'error'); });
}

function refreshLive() {
	return callLive().then(function(r) {
		liveData = r || { api: false, balancers: [], stale: [] };
		redrawLive();
	}, function() {});
}

function refresh() {
	return callGet().then(function(r) {
		outbounds = (r && r.outbounds) || [];
		working = ((r && r.balancers) || []).map(function(b) {
			return { tag: b.tag, selector: b.selector || [], strategy: b.strategy || 'random', fallbackTag: b.fallbackTag || '' };
		});
		redraw();
		refreshLive();   // outbound list for the pin dropdowns may have changed
	});
}

return view.extend({
	load: function() {
		return Promise.all([ refresh().catch(function() {}), checkUIVersion() ]);
	},
	render: function() {
		root = E('div', { 'class': 'cbi-section' });
		liveRoot = E('div', { 'class': 'cbi-section' });
		redraw();
		redrawLive();
		poll.add(refreshLive, 10);   // live picks + pin divergence, 10 s
		var nodes = [ E('h2', {}, _('Xray Balancers')), liveRoot, root ];
		if (staleUI) nodes.unshift(staleUI);
		return E('div', {}, nodes);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
