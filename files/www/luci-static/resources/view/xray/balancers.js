'use strict';
'require view';
'require rpc';
'require ui';

var callGet = rpc.declare({ object: 'xray-monitor', method: 'balancers_get' });
var callSet = rpc.declare({ object: 'xray-monitor', method: 'balancers_set', params: [ 'balancers' ] });

var STRATEGIES = [ 'leastPing', 'leastLoad', 'roundRobin', 'random' ];

var root = null;
var outbounds = [];      // [tag]
var working = [];        // [{tag, selector:[], strategy, fallbackTag}]
var rowEls = [];         // [{tag, strategy, fallback, members:{tag:checkbox}}]

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

function refresh() {
	return callGet().then(function(r) {
		outbounds = (r && r.outbounds) || [];
		working = ((r && r.balancers) || []).map(function(b) {
			return { tag: b.tag, selector: b.selector || [], strategy: b.strategy || 'random', fallbackTag: b.fallbackTag || '' };
		});
		redraw();
	});
}

return view.extend({
	load: function() { return refresh().catch(function() {}); },
	render: function() {
		root = E('div', { 'class': 'cbi-section' });
		redraw();
		return E('div', {}, [ E('h2', {}, _('Xray Balancers')), root ]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
