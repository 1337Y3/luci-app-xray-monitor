'use strict';
'require view';
'require rpc';
'require ui';

var callGet = rpc.declare({ object: 'xray-monitor', method: 'routing_get' });
var callSet = rpc.declare({ object: 'xray-monitor', method: 'routing_set', params: [ 'inbounds' ] });

var root = null;
var exits = [];          // [{tag, kind}]
var working = [];        // editable model: [{tag, port, exit}]
var rowEls = [];         // parallel DOM refs: [{tag, port, exit}]

function defaultExit() {
	for (var i = 0; i < exits.length; i++) if (exits[i].tag == 'direct') return 'direct';
	return exits.length ? exits[0].tag : '';
}

function syncFromInputs() {
	for (var i = 0; i < rowEls.length && i < working.length; i++) {
		working[i].tag  = rowEls[i].tag.value.trim();
		working[i].port = rowEls[i].port.value.trim();
		working[i].exit = rowEls[i].exit.value;
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
	return E('select', { 'class': 'cbi-input-select', 'style': 'min-width:170px;' }, opts);
}

function renderTable() {
	rowEls = [];
	var rows = [ E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('Inbound tag')),
		E('th', { 'class': 'th' }, _('tproxy port')),
		E('th', { 'class': 'th' }, _('Exit (outbound / balancer)')),
		E('th', { 'class': 'th', 'style': 'width:1%' }, '')
	]) ];

	working.forEach(function(row, idx) {
		var tagI  = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:160px', 'value': row.tag });
		var portI = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'style': 'width:90px', 'value': row.port, 'min': 1, 'max': 65535 });
		var exitS = mkExitSelect(row.exit);
		var del = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('Delete'));
		del.addEventListener('click', function() { syncFromInputs(); working.splice(idx, 1); renderTable(); });
		rowEls.push({ tag: tagI, port: portI, exit: exitS });
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, tagI),
			E('td', { 'class': 'td' }, portI),
			E('td', { 'class': 'td' }, exitS),
			E('td', { 'class': 'td' }, del)
		]));
	});

	if (!working.length)
		rows.push(E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'colspan': 4 }, E('em', {}, _('No tproxy inbounds. Add one below.'))) ]));

	var addBtn = E('button', { 'class': 'cbi-button cbi-button-add' }, _('+ Add inbound'));
	addBtn.addEventListener('click', function() {
		syncFromInputs();
		working.push({ tag: '', port: '', exit: defaultExit() });
		renderTable();
	});

	var saveBtn = E('button', { 'class': 'cbi-button cbi-button-save important' }, _('Save & apply'));
	saveBtn.addEventListener('click', function() { doSave(saveBtn); });

	var content = [
		E('h3', {}, _('tproxy inbounds → exits')),
		E('table', { 'class': 'table' }, rows),
		E('div', { 'style': 'margin:.6em 0;display:flex;gap:8px;' }, [ addBtn, saveBtn ]),
		E('div', { 'style': 'color:#888;font-size:90%;' }, [
			E('p', {}, _('Each row is a dokodemo-door tproxy inbound (your current format). The port must match what feeds it (e.g. ruantiblock t_proxy_port). Renaming a tag also re-points its routing rule.')),
			E('p', {}, _('Save validates with xray -test, backs up config.json, and restarts xray (auto-rollback if the test fails). Other routing rules, balancers, the api inbound and outbounds are left untouched.'))
		])
	];

	while (root.firstChild) root.removeChild(root.firstChild);
	content.forEach(function(n) { root.appendChild(n); });
}

function doSave(btn) {
	syncFromInputs();
	var seenTag = {}, seenPort = {};
	for (var i = 0; i < working.length; i++) {
		var r = working[i];
		if (!/^[A-Za-z0-9_.\-]+$/.test(r.tag))
			return ui.addNotification(null, E('p', _('Invalid tag: ') + (r.tag || '(empty)')), 'error');
		if (seenTag[r.tag]) return ui.addNotification(null, E('p', _('Duplicate tag: ') + r.tag), 'error');
		seenTag[r.tag] = 1;
		var p = parseInt(r.port, 10);
		if (!(p >= 1 && p <= 65535))
			return ui.addNotification(null, E('p', _('Invalid port for ') + r.tag), 'error');
		if (seenPort[p]) return ui.addNotification(null, E('p', _('Duplicate port: ') + p), 'error');
		seenPort[p] = 1;
	}
	if (!confirm(_('Apply routing changes and restart xray now?'))) return;
	btn.disabled = true;
	var payload = working.map(function(r) { return { tag: r.tag, port: parseInt(r.port, 10), exit: r.exit }; });
	callSet(payload).then(function(res) {
		btn.disabled = false;
		if (res && res.ok) {
			ui.addNotification(null, E('p', _('Routing applied and xray restarted.')), 'info');
			return refresh();
		}
		ui.addNotification(null, E('p', _('Apply failed — config not changed. ') + ((res && res.msg) || '')), 'error');
	}, function() { btn.disabled = false; ui.addNotification(null, E('p', _('Apply call failed.')), 'error'); });
}

function refresh() {
	return callGet().then(function(r) {
		exits = (r && r.exits) || [];
		working = ((r && r.inbounds) || []).map(function(i) {
			return { tag: i.tag, port: String(i.port), exit: i.exit };
		});
		renderTable();
	});
}

return view.extend({
	load: function() { return refresh().catch(function() {}); },

	render: function() {
		root = E('div', { 'class': 'cbi-section' });
		renderTable();
		return E('div', {}, [ E('h2', {}, _('Xray Routing')), root ]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
