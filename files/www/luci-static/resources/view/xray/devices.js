'use strict';
'require view';
'require rpc';
'require ui';

var callRules  = rpc.declare({ object: 'xray-monitor', method: 'rules_get' });
var callLeases = rpc.declare({ object: 'xray-monitor', method: 'dhcp_leases' });
var callSet    = rpc.declare({ object: 'xray-monitor', method: 'devices_set', params: [ 'devices' ] });

var LEASE_LIST_ID = 'xm-lease-list';

var root = null;
var managed = false;
var lists = [];        // [{name, enabled}]
var leases = [];       // [{ip, mac, host}]
var working = [];      // [{name, ip, bypass_all, bypass:[], enabled}]
var rowEls = [];       // [{name, ip, bypassAll, boxes:{name:checkbox}, enabled}]

function syncFromInputs() {
	for (var i = 0; i < rowEls.length && i < working.length; i++) {
		var el = rowEls[i];
		working[i].name = el.name.value.trim();
		working[i].ip = el.ip.value.trim();
		working[i].bypass_all = el.bypassAll.checked;
		working[i].enabled = el.enabled.checked;
		var sel = [];
		for (var n in el.boxes) if (el.boxes[n].checked) sel.push(n);
		working[i].bypass = sel;
	}
}

function buildLeaseList() {
	return E('datalist', { 'id': LEASE_LIST_ID }, leases.map(function(l) {
		var label = l.ip + (l.host ? ' (' + l.host + ')' : '');
		return E('option', { 'value': l.ip, 'label': label }, label);
	}));
}

function buildRow(dev, idx) {
	var nameI = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:140px', 'value': dev.name, 'placeholder': _('e.g. TV') });
	var ipI = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:130px', 'value': dev.ip, 'list': LEASE_LIST_ID, 'placeholder': '192.168.1.x' });
	var allCb = E('input', { 'type': 'checkbox', 'checked': dev.bypass_all ? '' : null });
	var enCb = E('input', { 'type': 'checkbox', 'checked': dev.enabled ? '' : null });

	var boxes = {};
	var boxEls = [];
	lists.forEach(function(l) {
		var cb = E('input', { 'type': 'checkbox', 'checked': (dev.bypass.indexOf(l.name) >= 0) ? '' : null });
		boxes[l.name] = cb;
		boxEls.push(E('label', { 'style': 'display:inline-flex;align-items:center;gap:4px;margin:2px 10px 2px 0;' }, [
			cb, E('span', { 'style': l.enabled ? '' : 'color:#888;' }, l.name + (l.enabled ? '' : ' ' + _('(off)')))
		]));
	});
	var regCb = E('input', { 'type': 'checkbox', 'checked': (dev.bypass.indexOf('registry') >= 0) ? '' : null });
	boxes['registry'] = regCb;
	boxEls.push(E('label', { 'style': 'display:inline-flex;align-items:center;gap:4px;margin:2px 10px 2px 0;' }, [
		regCb, E('span', {}, _('registry'))
	]));

	function applyAllState() {
		for (var n in boxes) boxes[n].disabled = allCb.checked;
	}
	allCb.addEventListener('change', applyAllState);
	applyAllState();

	var del = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('Delete'));
	del.addEventListener('click', function() { syncFromInputs(); working.splice(idx, 1); redraw(); });

	rowEls.push({ name: nameI, ip: ipI, bypassAll: allCb, boxes: boxes, enabled: enCb });

	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td' }, nameI),
		E('td', { 'class': 'td' }, ipI),
		E('td', { 'class': 'td', 'style': 'text-align:center;' }, allCb),
		E('td', { 'class': 'td' }, boxEls),
		E('td', { 'class': 'td', 'style': 'text-align:center;' }, enCb),
		E('td', { 'class': 'td', 'style': 'white-space:nowrap;' }, del)
	]);
}

function redraw() {
	rowEls = [];

	var head = E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('Name')),
		E('th', { 'class': 'th' }, _('IP')),
		E('th', { 'class': 'th' }, _('Bypass everything')),
		E('th', { 'class': 'th' }, _('Per-list bypass')),
		E('th', { 'class': 'th' }, _('Enabled')),
		E('th', { 'class': 'th', 'style': 'width:1%' }, '')
	]);
	var rows = [ head ];
	working.forEach(function(d, i) { rows.push(buildRow(d, i)); });
	if (!working.length)
		rows.push(E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'colspan': 6 }, E('em', {}, _('No devices. Add one below.'))) ]));

	var addBtn = E('button', { 'class': 'cbi-button cbi-button-add' }, _('+ Add device'));
	addBtn.addEventListener('click', function() {
		syncFromInputs();
		working.push({ name: '', ip: '', bypass_all: false, bypass: [], enabled: true });
		redraw();
	});
	var saveBtn = E('button', { 'class': 'cbi-button cbi-button-save important' }, _('Save & apply'));
	saveBtn.addEventListener('click', function() { doSave(saveBtn); });

	var content = [];
	if (!managed)
		content.push(E('div', { 'class': 'alert-message warning' },
			_('Managed routing is OFF — edits are saved to the router but not applied to xray until migration enables it.')));

	content.push(
		E('h3', {}, _('LAN devices')),
		buildLeaseList(),
		E('table', { 'class': 'table' }, rows),
		E('div', { 'style': 'margin:.6em 0;display:flex;gap:8px;' }, [ addBtn, saveBtn ]),
		E('div', { 'style': 'color:#888;font-size:90%;' }, [
			E('p', {}, _('"Bypass everything" removes the device from the tproxy firewall entirely (fastest path, kernel-level) — its traffic never enters xray at all.')),
			E('p', {}, _('Per-list bypass sends that list\'s destinations direct for this device only (matched inside xray by source IP); "registry" = the auto RKN-blocked set.'))
		])
	);

	while (root.firstChild) root.removeChild(root.firstChild);
	content.forEach(function(n) { root.appendChild(n); });
}

function doSave(btn) {
	syncFromInputs();
	var seen = {};
	for (var i = 0; i < working.length; i++) {
		var d = working[i];
		if (!/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(d.ip))
			return ui.addNotification(null, E('p', _('Invalid IPv4 address: ') + (d.ip || _('(empty)'))), 'error');
		if (seen[d.ip])
			return ui.addNotification(null, E('p', _('Duplicate IP: ') + d.ip), 'error');
		seen[d.ip] = 1;
	}
	var q = managed
		? _('Apply device rules and restart xray now?')
		: _('Save devices? (managed routing is off — nothing is applied yet)');
	if (!confirm(q)) return;
	btn.disabled = true;
	var payload = working.map(function(d) {
		return { name: d.name, ip: d.ip, bypass_all: d.bypass_all ? '1' : '0', bypass: d.bypass, enabled: d.enabled ? '1' : '0' };
	});
	callSet(payload).then(function(res) {
		btn.disabled = false;
		if (res && res.ok) {
			ui.addNotification(null, E('p', managed ? _('Device rules applied.') : _('Devices saved.')), 'info');
			return refresh();
		}
		ui.addNotification(null, E('p', _('Save failed. ') + ((res && res.msg) || '')), 'error');
	}, function() { btn.disabled = false; ui.addNotification(null, E('p', _('Save call failed.')), 'error'); });
}

function refresh() {
	return Promise.all([ callRules(), callLeases().catch(function() { return {}; }) ]).then(function(rs) {
		var r = rs[0] || {};
		managed = !!r.managed;
		lists = ((r.lists) || []).map(function(l) { return { name: l.name, enabled: !!l.enabled }; });
		leases = ((rs[1] && rs[1].leases) || []);
		working = ((r.devices) || []).map(function(d) {
			return { name: d.name || '', ip: d.ip || '', bypass_all: !!d.bypass_all, bypass: d.bypass || [], enabled: !!d.enabled };
		});
		redraw();
	});
}

return view.extend({
	load: function() { return refresh().catch(function() {}); },
	render: function() {
		root = E('div', { 'class': 'cbi-section' });
		redraw();
		return E('div', {}, [ E('h2', {}, _('Xray Devices')), root ]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
