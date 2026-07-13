'use strict';
'require view';
'require rpc';
'require ui';

var callGet     = rpc.declare({ object: 'xray-monitor', method: 'rules_get' });
var callSet     = rpc.declare({ object: 'xray-monitor', method: 'inbounds_set', params: [ 'inbounds' ] });
var callRouting = rpc.declare({ object: 'xray-monitor', method: 'routing_set', params: [ 'mode' ] });
var callApply   = rpc.declare({ object: 'xray-monitor', method: 'rules_apply' });

var NAME_RE = /^[A-Za-z0-9_-]{1,32}$/;

var root = null;
var exits = [];          // [{tag, kind}]
var managed = false;
var mode = 'lists';
var warnings = [];
var working = [];        // [{name, port, exit, enabled, order}]
var rowEls = [];

function defaultExit() {
	for (var i = 0; i < exits.length; i++) if (exits[i].tag == 'direct') return 'direct';
	return exits.length ? exits[0].tag : '';
}

function syncFromInputs() {
	for (var i = 0; i < rowEls.length && i < working.length; i++) {
		var el = rowEls[i];
		working[i].name    = el.name.value.trim();
		working[i].port    = el.port.value.trim();
		working[i].exit    = el.exit.value;
		working[i].enabled = el.enabled.checked;
		working[i].order   = el.order.value.trim();
	}
}

function mkExitSelect(sel) {
	var opts = [];
	exits.forEach(function(e) {
		opts.push(E('option', { 'value': e.tag, 'selected': (e.tag == sel) ? '' : null },
			e.tag + (e.kind == 'balancer' ? ' (balancer)' : '')));
	});
	if (!exits.some(function(e) { return e.tag == sel; }) && sel)
		opts.unshift(E('option', { 'value': sel, 'selected': '' }, sel + ' (missing!)'));
	return E('select', { 'class': 'cbi-input-select', 'style': 'min-width:180px;' }, opts);
}

function buildRow(ib, idx) {
	var discovered = (ib.source == 'config');
	var nameI = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:120px',
		'value': ib.name, 'placeholder': 'de' });
	var portI = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:80px',
		'value': ib.port, 'placeholder': '1100' });
	var exitS = mkExitSelect(ib.exit);
	var enCb  = E('input', { 'type': 'checkbox', 'checked': ib.enabled ? '' : null });
	var ordI  = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:60px',
		'value': ib.order });

	var del = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('Delete'));
	del.addEventListener('click', function() {
		syncFromInputs();
		working.splice(idx, 1);
		renderTable();
	});

	rowEls.push({ name: nameI, port: portI, exit: exitS, enabled: enCb, order: ordI });

	var tagLine = [ E('span', {}, 'tproxy-in-' + (ib.name || '?')) ];
	if (discovered)
		tagLine.push(E('span', {
			'style': 'margin-left:6px;padding:1px 5px;border-radius:3px;background:#f0ad4e;color:#fff;font-size:90%;',
			'title': _('Live in config.json but not stored in UCI yet. Press Save & Apply to adopt it.')
		}, _('from config.json')));

	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td' }, [ nameI,
			E('div', { 'style': 'color:#888;font-size:85%;margin-top:2px;' }, tagLine) ]),
		E('td', { 'class': 'td' }, portI),
		E('td', { 'class': 'td' }, exitS),
		E('td', { 'class': 'td', 'style': 'text-align:center;' }, enCb),
		E('td', { 'class': 'td' }, ordI),
		E('td', { 'class': 'td', 'style': 'text-align:right;' }, del)
	]);
}

function handleAdd() {
	syncFromInputs();
	var maxOrder = 0;
	working.forEach(function(r) { maxOrder = Math.max(maxOrder, parseInt(r.order, 10) || 0); });
	working.push({ name: '', port: '', exit: defaultExit(), enabled: true,
		order: String(maxOrder + 10), source: 'uci' });
	renderTable();
}

function handleSave(btn) {
	syncFromInputs();

	for (var i = 0; i < working.length; i++) {
		var r = working[i];
		if (!NAME_RE.test(r.name))
			return ui.addNotification(null, E('p', _('Invalid name: ') + (r.name || '(empty)')), 'error');
		var p = parseInt(r.port, 10);
		if (!(p >= 1 && p <= 65535))
			return ui.addNotification(null, E('p', _('Invalid port for ') + r.name + ': ' + r.port), 'error');
		if (!r.exit)
			return ui.addNotification(null, E('p', _('No exit selected for ') + r.name), 'error');
	}

	var q = (mode == 'inbounds')
		? _('Apply the inbound → exit map and restart xray now?')
		: _('Save the inbound map? Routing mode is "lists", so it is stored but NOT applied to xray.');
	if (!confirm(q)) return;

	btn.disabled = true;
	var payload = working.map(function(r) {
		return { name: r.name, port: parseInt(r.port, 10), exit: r.exit,
			enabled: r.enabled ? '1' : '0', order: parseInt(r.order, 10) };
	});
	callSet(payload).then(function(res) {
		btn.disabled = false;
		if (res && res.ok) {
			ui.addNotification(null, E('p', res.msg || _('Inbounds saved.')), 'info');
			return refresh();
		}
		ui.addNotification(null, E('p', (res && res.msg) || _('Save failed.')), 'error');
	}, function() {
		btn.disabled = false;
		ui.addNotification(null, E('p', _('Save call failed.')), 'error');
	});
}

function handleModeSwitch(newMode, btn) {
	var q = (newMode == 'inbounds')
		? _('Switch routing to "inbounds"?\n\nxray becomes a plain inbound → exit map with NO domain rules. ' +
		    'Your Lists / Devices / Registry rules stop being applied (their data is kept). ' +
		    'An external steerer (ruantiblock) must be running — it decides what gets proxied.')
		: _('Switch routing to "lists"?\n\nxray goes back to a single tproxy inbound with domain/geo rules ' +
		    'from the Lists page. Make sure ruantiblock is stopped and xray-fw is enabled, ' +
		    'or nothing will be proxied.');
	if (!confirm(q)) return;

	btn.disabled = true;
	callRouting(newMode).then(function(res) {
		if (!res || !res.ok) {
			btn.disabled = false;
			return ui.addNotification(null, E('p', (res && res.msg) || _('Mode switch failed.')), 'error');
		}
		// persisting the mode does not rewrite config.json — apply explicitly
		return callApply().then(function(a) {
			btn.disabled = false;
			if (a && a.ok) ui.addNotification(null, E('p', _('Routing mode is now: ') + newMode), 'info');
			else ui.addNotification(null, E('p', (a && a.msg) || _('Apply failed.')), 'error');
			return refresh();
		});
	}, function() {
		btn.disabled = false;
		ui.addNotification(null, E('p', _('Mode switch call failed.')), 'error');
	});
}

function renderTable() {
	rowEls = [];
	var rows = working.map(buildRow);

	var addBtn = E('button', { 'class': 'cbi-button cbi-button-add' }, _('Add inbound'));
	addBtn.addEventListener('click', handleAdd);

	var saveBtn = E('button', { 'class': 'cbi-button cbi-button-save' }, _('Save & Apply'));
	saveBtn.addEventListener('click', function() { handleSave(saveBtn); });

	var other = (mode == 'inbounds') ? 'lists' : 'inbounds';
	var modeBtn = E('button', { 'class': 'cbi-button cbi-button-action' },
		_('Switch to "%s" mode').format(other));
	modeBtn.addEventListener('click', function() { handleModeSwitch(other, modeBtn); });

	var banner;
	if (!managed) {
		banner = E('div', { 'class': 'alert-message warning' }, [
			E('strong', {}, _('Managed routing is OFF.')), ' ',
			_('xray-monitor will not touch config.json (uci xray-monitor.rules.managed=0), so nothing here is applied. Set it to 1 to let this page drive routing.')
		]);
	} else if (mode == 'inbounds') {
		banner = E('div', { 'class': 'alert-message info' }, [
			E('strong', {}, _('Mode: inbounds (ruantiblock).')), ' ',
			_('xray is a plain inbound → exit map — no domain rules, no default rule. ruantiblock decides WHAT is proxied (destination-IP nftsets) and tproxies it to the port below; xray decides WHERE it exits. Each port here must match that list\'s '),
			E('code', {}, 'u_t_proxy_port_tcp'), _(' in ruantiblock. The Lists / Devices / Registry pages are inactive in this mode.')
		]);
	} else {
		banner = E('div', { 'class': 'alert-message info' }, [
			E('strong', {}, _('Mode: lists (xray-native).')), ' ',
			_('xray uses ONE tproxy inbound and routes by domain/geo rules from the Lists page. The map below is stored but NOT applied. Switch to "inbounds" mode to use it.')
		]);
	}

	var nDisc = working.filter(function(r) { return r.source == 'config'; }).length;
	var adoptBox = nDisc
		? E('div', { 'class': 'alert-message warning' }, [
			E('strong', {}, _('%d inbound(s) read from config.json').format(nDisc)), ' ',
			_('They are live in xray but not stored in UCI, so the app is not managing them yet. Review the exits below and press '),
			E('em', {}, _('Save & Apply')), _(' to adopt them — the generated config is identical, so nothing changes on the wire.')
		])
		: '';

	var warnBox = warnings.length
		? E('div', { 'class': 'alert-message warning' },
			[ E('strong', {}, _('Warnings')), E('ul', {}, warnings.map(function(w) { return E('li', {}, w); })) ])
		: '';

	var table = E('table', { 'class': 'table cbi-section-table' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Name / xray tag')),
			E('th', { 'class': 'th' }, _('tproxy port')),
			E('th', { 'class': 'th' }, _('Exit (outbound / balancer)')),
			E('th', { 'class': 'th', 'style': 'text-align:center;' }, _('Enabled')),
			E('th', { 'class': 'th' }, _('Order')),
			E('th', { 'class': 'th' }, '')
		])
	].concat(rows.length ? rows : [
		E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', 'colspan': 6, 'style': 'color:#888;' },
			_('No inbounds defined. Add one per ruantiblock list.')))
	]));

	var content = [
		banner, adoptBox, warnBox, table,
		E('div', { 'style': 'margin-top:.8em;' }, [ addBtn, ' ', saveBtn, ' ', modeBtn ])
	];

	while (root.firstChild) root.removeChild(root.firstChild);
	content.forEach(function(c) { if (c) root.appendChild(c); });
}

function refresh() {
	return callGet().then(function(r) {
		exits    = (r && r.exits) || [];
		managed  = !!(r && r.managed);
		mode     = (r && r.mode) || 'lists';
		warnings = (r && r.warnings) || [];
		working  = ((r && r.inbounds) || []).map(function(ib) {
			return { name: ib.name, port: String(ib.port), exit: ib.exit,
				enabled: !!ib.enabled, order: String(ib.order),
				source: ib.source || 'uci' };
		});
		renderTable();
	});
}

return view.extend({
	load: function() { return refresh().catch(function() {}); },

	render: function() {
		root = E('div', { 'class': 'cbi-section' });
		renderTable();
		return E('div', {}, [ E('h2', {}, _('Xray Inbounds → Exits')), root ]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
