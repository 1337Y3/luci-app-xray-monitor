'use strict';
'require view';
'require rpc';
'require ui';

var callGet     = rpc.declare({ object: 'xray-monitor', method: 'rules_get' });
var callEntries = rpc.declare({ object: 'xray-monitor', method: 'list_entries', params: [ 'name' ] });
var callSet     = rpc.declare({ object: 'xray-monitor', method: 'lists_set', params: [ 'lists' ] });

var NAME_RE = /^[A-Za-z0-9_-]{1,32}$/;
var DNS_RE  = /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(#\d{1,5})?$/;

var root = null;
var exits = [];          // [{tag, kind}]
var managed = false;
var warnings = [];
// editable model: [{name, origName, exit, dns, enabled, order, counts:{domain,ip}, dirty, loaded}]
// dirty = entries text edited this session (string -> sent on save, null -> file left untouched)
// loaded = per-row cache of list_entries so we only fetch once per row
var working = [];
var rowEls = [];         // parallel DOM refs: [{name, enabled, exit, dns, order}]

function defaultExit() {
	for (var i = 0; i < exits.length; i++) if (exits[i].tag == 'direct') return 'direct';
	return exits.length ? exits[0].tag : '';
}

function syncFromInputs() {
	for (var i = 0; i < rowEls.length && i < working.length; i++) {
		var el = rowEls[i];
		working[i].name    = el.name.value.trim();
		working[i].enabled = el.enabled.checked;
		working[i].exit    = el.exit.value;
		working[i].dns     = el.dns.value.trim();
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
	return E('select', { 'class': 'cbi-input-select', 'style': 'min-width:170px;' }, opts);
}

function openEntriesModal(row) {
	var text = (typeof row.dirty == 'string') ? row.dirty : row.loaded;
	var ta = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 18,
		'style': 'width:100%;font-family:monospace;white-space:pre;' });
	ta.value = text || '';

	var cancel = E('button', { 'class': 'cbi-button cbi-button-neutral' }, _('Cancel'));
	cancel.addEventListener('click', function() { ui.hideModal(); });
	var use = E('button', { 'class': 'cbi-button cbi-button-save' }, _('Use'));
	use.addEventListener('click', function() {
		syncFromInputs();
		row.dirty = ta.value;
		ui.hideModal();
		renderTable();
	});

	ui.showModal(_('Entries: ') + (row.name || row.origName || _('(new list)')), [
		E('p', { 'style': 'color:#888;font-size:90%;margin:.2em 0 .6em;' },
			_('One entry per line; "#" starts a comment. A bare domain is a suffix match; full:/regexp:/keyword:/geosite: prefixes, IPv4 addresses and CIDR ranges are also accepted.')),
		ta,
		E('div', { 'class': 'right', 'style': 'margin-top:.6em;' }, [ cancel, ' ', use ])
	]);
}

function handleEdit(row, btn) {
	// already edited this session, cached from a previous open, or a new row — open straight away
	if (typeof row.dirty == 'string' || typeof row.loaded == 'string' || !row.origName)
		return openEntriesModal(row);
	btn.disabled = true;
	callEntries(row.origName).then(function(r) {
		btn.disabled = false;
		row.loaded = (r && typeof r.entries == 'string') ? r.entries : '';
		openEntriesModal(row);
	}, function() {
		btn.disabled = false;
		ui.addNotification(null, E('p', _('Failed to load entries for ') + row.origName), 'error');
	});
}

function renderTable() {
	rowEls = [];
	var rows = [ E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('Name')),
		E('th', { 'class': 'th' }, _('Enabled')),
		E('th', { 'class': 'th' }, _('Exit')),
		E('th', { 'class': 'th' }, _('DNS')),
		E('th', { 'class': 'th', 'style': 'width:5em' }, _('Order')),
		E('th', { 'class': 'th' }, _('Entries')),
		E('th', { 'class': 'th', 'style': 'width:1%' }, '')
	]) ];

	working.forEach(function(row, idx) {
		var nameI = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:130px', 'value': row.name });
		var enI   = E('input', { 'type': 'checkbox', 'checked': row.enabled ? '' : null });
		var exitS = mkExitSelect(row.exit);
		var dnsI  = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:190px',
			'value': row.dns, 'placeholder': '127.0.0.1#5053, 127.0.0.1#5054',
			'title': _('Per-list dnsmasq upstream(s) for this list\'s domains; comma = failover.') });
		var orderI = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'style': 'width:4.5em',
			'value': row.order, 'title': _('Lower = matched earlier') });

		var counts = row.counts || {};
		var cells = [ E('span', { 'style': 'color:#888;white-space:nowrap;' },
			(counts.domain || 0) + ' ' + _('dom') + ' / ' + (counts.ip || 0) + ' ' + _('ip')) ];
		if (typeof row.dirty == 'string')
			cells.push(E('span', { 'style': 'color:#cc7a00;font-size:90%;' }, ' ' + _('(edited)')));
		var editB = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Edit'));
		editB.addEventListener('click', function() { handleEdit(row, editB); });
		cells.push(' ', editB);

		var del = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('Delete'));
		del.addEventListener('click', function() { syncFromInputs(); working.splice(idx, 1); renderTable(); });

		rowEls.push({ name: nameI, enabled: enI, exit: exitS, dns: dnsI, order: orderI });
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, nameI),
			E('td', { 'class': 'td' }, enI),
			E('td', { 'class': 'td' }, exitS),
			E('td', { 'class': 'td' }, dnsI),
			E('td', { 'class': 'td' }, orderI),
			E('td', { 'class': 'td', 'style': 'white-space:nowrap' }, cells),
			E('td', { 'class': 'td' }, del)
		]));
	});

	if (!working.length)
		rows.push(E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'colspan': 7 }, E('em', {}, _('No lists. Add one below.'))) ]));

	var addBtn = E('button', { 'class': 'cbi-button cbi-button-add' }, _('+ Add list'));
	addBtn.addEventListener('click', function() {
		syncFromInputs();
		var maxOrder = 0;
		working.forEach(function(r) { var o = parseInt(r.order, 10); if (o > maxOrder) maxOrder = o; });
		working.push({ name: '', origName: null, exit: defaultExit(), dns: '', enabled: true,
			order: String(maxOrder + 10), counts: { domain: 0, ip: 0 }, dirty: '', loaded: null });
		renderTable();
	});

	var saveBtn = E('button', { 'class': 'cbi-button cbi-button-save important' }, _('Save & apply'));
	saveBtn.addEventListener('click', function() { doSave(saveBtn); });

	var content = [];

	if (!managed)
		content.push(E('div', { 'style': 'padding:.5em;border:1px solid #d4b106;background:rgba(212,177,6,.1);margin-bottom:.6em;border-radius:4px' },
			_('Managed routing is OFF — edits are saved to the router but not applied to xray until migration enables it.')));

	if (warnings.length)
		content.push(E('div', { 'style': 'padding:.5em;border:1px solid #cc3300;background:rgba(204,51,0,.08);margin-bottom:.6em;border-radius:4px' },
			warnings.map(function(w) { return E('div', {}, w); })));

	content.push(
		E('h3', {}, _('Domain / IP lists → exits')),
		E('table', { 'class': 'table' }, rows),
		E('div', { 'style': 'margin:.6em 0;display:flex;gap:8px;' }, [ addBtn, saveBtn ]),
		E('div', { 'style': 'color:#888;font-size:90%;' }, [
			E('p', {}, _('Each list maps a set of domains/IPs to an exit (outbound or balancer); lower order is matched earlier. The special exit "direct" bypasses all proxies.')),
			E('p', {}, _('DNS is optional: per-list dnsmasq upstream(s) used to resolve this list\'s domains (comma-separated = failover). Per-device bypassing lives on the Devices page.'))
		])
	);

	while (root.firstChild) root.removeChild(root.firstChild);
	content.forEach(function(n) { root.appendChild(n); });
}

function doSave(btn) {
	syncFromInputs();
	var seen = {};
	for (var i = 0; i < working.length; i++) {
		var r = working[i];
		if (!NAME_RE.test(r.name))
			return ui.addNotification(null, E('p', _('Invalid list name: ') + (r.name || '(empty)') + _(' (letters/digits/-/_ only, max 32)')), 'error');
		if (seen[r.name])
			return ui.addNotification(null, E('p', _('Duplicate list name: ') + r.name), 'error');
		seen[r.name] = 1;
		if (!r.exit)
			return ui.addNotification(null, E('p', _('No exit selected for ') + r.name), 'error');
		if (r.dns) {
			var parts = r.dns.split(',');
			for (var j = 0; j < parts.length; j++) {
				if (!DNS_RE.test(parts[j].trim()))
					return ui.addNotification(null, E('p', _('Invalid DNS server for ') + r.name + ': ' + parts[j].trim()), 'error');
			}
		}
		if (isNaN(parseInt(r.order, 10)))
			return ui.addNotification(null, E('p', _('Invalid order for ') + r.name), 'error');
	}

	var q = managed
		? _('Apply lists and restart xray now?')
		: _('Save lists? (managed routing is off — nothing is applied yet)');
	if (!confirm(q)) return;

	btn.disabled = true;
	var payload = working.map(function(r) {
		var item = { name: r.name, exit: r.exit, dns: r.dns,
			enabled: r.enabled ? '1' : '0', order: parseInt(r.order, 10) };
		// carry the original name so a rename moves the entries file instead of
		// orphaning it (backend renames when name != orig and no entries sent)
		if (r.origName) item.orig = r.origName;
		// only rows edited this session (and new rows) carry entries; omitted = file untouched
		if (typeof r.dirty == 'string') item.entries = r.dirty;
		return item;
	});
	callSet(payload).then(function(res) {
		btn.disabled = false;
		if (res && res.ok) {
			ui.addNotification(null, E('p', res.msg || _('Lists saved.')), 'info');
			return refresh();
		}
		ui.addNotification(null, E('p', (res && res.msg) || _('Save failed.')), 'error');
	}, function() { btn.disabled = false; ui.addNotification(null, E('p', _('Save call failed.')), 'error'); });
}

function refresh() {
	return callGet().then(function(r) {
		exits    = (r && r.exits) || [];
		managed  = !!(r && r.managed);
		warnings = (r && r.warnings) || [];
		working = ((r && r.lists) || []).map(function(l) {
			return { name: l.name, origName: l.name, exit: l.exit, dns: l.dns || '',
				enabled: !!l.enabled, order: String(l.order),
				counts: l.counts || { domain: 0, ip: 0 }, dirty: null, loaded: null };
		});
		renderTable();
	});
}

return view.extend({
	load: function() { return refresh().catch(function() {}); },

	render: function() {
		root = E('div', { 'class': 'cbi-section' });
		renderTable();
		return E('div', {}, [ E('h2', {}, _('Xray Lists')), root ]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
