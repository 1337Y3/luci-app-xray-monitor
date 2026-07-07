'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var callGet     = rpc.declare({ object: 'xray-monitor', method: 'rules_get' });
var callGlobals = rpc.declare({ object: 'xray-monitor', method: 'routing_set',
	params: [ 'default_exit', 'registry_enabled', 'registry_exit', 'registry_geosite', 'registry_geoip', 'tproxy_port' ] });
var callGeorules = rpc.declare({ object: 'xray-monitor', method: 'georules_set', params: [ 'rules' ] });
var callFwGet   = rpc.declare({ object: 'xray-monitor', method: 'fw_get' });
var callFwSet   = rpc.declare({ object: 'xray-monitor', method: 'fw_set', params: [ 'enabled' ] });
var callApply   = rpc.declare({ object: 'xray-monitor', method: 'rules_apply' });

var root = null;
var state = { exits: [], managed: false, tproxy_port: 1200, default_exit: 'direct',
              registry: { enabled: false, exit: '', geosite: '', geoip: '' },
              georules: [], geodata_present: false, warnings: [] };
var fw = {};
var grEls = [];          // parallel refs for the georule table
var gEls = {};           // globals form refs

function mkExitSelect(sel, extra) {
	var opts = [];
	state.exits.forEach(function(e) {
		opts.push(E('option', { 'value': e.tag, 'selected': (e.tag == sel) ? '' : null },
			e.tag + (e.kind == 'balancer' ? ' (balancer)' : '')));
	});
	if (!state.exits.some(function(e) { return e.tag == sel; }) && sel)
		opts.unshift(E('option', { 'value': sel, 'selected': '' }, sel + ' (missing!)'));
	return E('select', { 'class': 'cbi-input-select', 'style': extra || 'min-width:160px' }, opts);
}

function badge(label, ok) {
	return E('span', { 'style': 'display:inline-block;margin:0 6px 4px 0;padding:2px 8px;border-radius:10px;font-size:85%;color:#fff;background:' + (ok ? '#46a546' : '#999') }, label);
}

/* ---- transparent-proxy panel ---- */
function renderFwPanel() {
	var on = !!(fw && fw.enabled);
	var toggle = E('button', {
		'class': 'cbi-button ' + (on ? 'cbi-button-negative' : 'cbi-button-positive'),
		'click': function() {
			var q = on ? _('Turn the transparent proxy OFF? LAN TCP will flow direct (no proxying).')
			           : _('Turn the transparent proxy ON? All LAN TCP will be routed through xray.');
			if (!confirm(q)) return;
			callFwSet(on ? '0' : '1').then(function(res) {
				if (!(res && res.ok)) ui.addNotification(null, E('p', {}, _('Toggle failed. ') + ((res && res.msg) || '')), 'error');
				refresh();
			});
		}
	}, on ? _('Turn OFF') : _('Turn ON'));

	return E('div', { 'class': 'cbi-section', 'style': 'border:1px solid #ddd;padding:10px;border-radius:6px' }, [
		E('h3', {}, _('Transparent proxy (tproxy)')),
		E('div', {}, [
			badge(_('firewall ') + (fw.enabled ? _('enabled') : _('off')), !!fw.enabled),
			badge(_('managed'), !!fw.managed),
			badge(_('nft table'), !!fw.active),
			badge(_('ip rule'), !!fw.rule_present),
			badge(_('port ') + (fw.port || '?') + (fw.port_listening ? ' ' + _('listening') : ''), !!fw.port_listening),
			badge(_('watchdog'), !!fw.watchdog_running)
		]),
		E('div', { 'style': 'margin:.5em 0' }, toggle),
		E('div', { 'style': 'color:#888;font-size:90%' }, [
			E('p', {}, _('When ON, all LAN TCP is tproxy\'d into xray on port ') + (fw.port || state.tproxy_port) + _('. UDP is untouched. If xray goes down the watchdog removes the rules within ~5s so the LAN keeps working.')),
			E('p', {}, [ _('Emergency kill switch from a shell: '), E('code', {}, '/usr/share/xray-monitor/xray-fw off') ])
		])
	]);
}

/* ---- globals panel ---- */
function renderGlobals() {
	gEls = {};
	gEls.tproxy_port = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'style': 'width:6em', 'value': state.tproxy_port, 'min': 1, 'max': 65535 });
	gEls.default_exit = mkExitSelect(state.default_exit);
	gEls.registry_enabled = E('input', { 'type': 'checkbox' }); gEls.registry_enabled.checked = !!state.registry.enabled;
	gEls.registry_exit = mkExitSelect(state.registry.exit);
	gEls.registry_geosite = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:10em', 'value': state.registry.geosite || '' });
	gEls.registry_geoip = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:10em', 'value': state.registry.geoip || '' });

	var saveBtn = E('button', { 'class': 'cbi-button cbi-button-save important', 'click': function() { saveGlobals(saveBtn); } }, _('Save globals & apply'));

	function row(label, ctl) {
		return E('div', { 'class': 'cbi-value', 'style': 'display:flex;gap:10px;align-items:center;margin:.3em 0' }, [
			E('label', { 'style': 'min-width:14em' }, label), ctl ]);
	}
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, _('Routing globals')),
		row(_('tproxy port'), gEls.tproxy_port),
		row(_('Default exit (unmatched)'), gEls.default_exit),
		row(_('RKN registry auto-route'), gEls.registry_enabled),
		row(_('Registry exit'), gEls.registry_exit),
		row(_('Registry geosite tag'), gEls.registry_geosite),
		row(_('Registry geoip tag'), gEls.registry_geoip),
		state.geodata_present ? null : E('p', { 'style': 'color:#cc7a00' }, _('Geodata (.dat) files are not installed — registry and geosite/geoip rules will not apply until you run a Geodata update.')),
		E('div', { 'style': 'margin:.5em 0' }, saveBtn)
	]);
}

function saveGlobals(btn) {
	var port = parseInt(gEls.tproxy_port.value, 10);
	if (!(port >= 1 && port <= 65535))
		return ui.addNotification(null, E('p', {}, _('Invalid tproxy port')), 'error');
	if (state.managed && !confirm(_('Apply routing globals and restart xray now?'))) return;
	btn.disabled = true;
	callGlobals(gEls.default_exit.value, gEls.registry_enabled.checked ? '1' : '0',
		gEls.registry_exit.value, gEls.registry_geosite.value.trim(), gEls.registry_geoip.value.trim(),
		String(port)).then(function(res) {
		btn.disabled = false;
		if (res && res.ok) { ui.addNotification(null, E('p', {}, res.msg || _('Saved.')), 'info'); return refresh(); }
		ui.addNotification(null, E('p', {}, _('Save failed. ') + ((res && res.msg) || '')), 'error');
	}, function() { btn.disabled = false; ui.addNotification(null, E('p', {}, _('Save call failed.')), 'error'); });
}

/* ---- geo-rules table ---- */
function syncGeorules() {
	for (var i = 0; i < grEls.length && i < state.georules.length; i++) {
		var e = grEls[i], g = state.georules[i];
		g.name    = e.name.value.trim();
		g.enabled = e.enabled.checked;
		g.order   = e.order.value.trim();
		g.domain  = splitList(e.domain.value);
		g.ip      = splitList(e.ip.value);
		g.source  = splitList(e.source.value);
		g.network = e.network.value;
		g.exit    = e.exit.value;
	}
}
function splitList(s) {
	return (s || '').split(/[\s,]+/).map(function(x) { return x.trim(); }).filter(function(x) { return x.length; });
}

function renderGeorules() {
	grEls = [];
	var rows = [ E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('On')),
		E('th', { 'class': 'th' }, _('Name')),
		E('th', { 'class': 'th' }, _('Domains / geosite')),
		E('th', { 'class': 'th' }, _('IPs / geoip')),
		E('th', { 'class': 'th' }, _('Source IPs')),
		E('th', { 'class': 'th' }, _('Net')),
		E('th', { 'class': 'th' }, _('Exit')),
		E('th', { 'class': 'th', 'style': 'width:4em' }, _('Order')),
		E('th', { 'class': 'th', 'style': 'width:1%' }, '')
	]) ];

	state.georules.forEach(function(g, idx) {
		var enI = E('input', { 'type': 'checkbox' }); enI.checked = g.enabled !== false;
		var nameI = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:8em', 'value': g.name || '' });
		var domI = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:12em', 'value': (g.domain || []).join(', '), 'placeholder': 'geosite:youtube' });
		var ipI = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:10em', 'value': (g.ip || []).join(', '), 'placeholder': 'geoip:ru' });
		var srcI = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:9em', 'value': (g.source || []).join(', ') });
		var netS = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': '', 'selected': (!g.network) ? '' : null }, _('any')),
			E('option', { 'value': 'tcp', 'selected': (g.network == 'tcp') ? '' : null }, 'tcp')
		]);
		var exitS = mkExitSelect(g.exit, 'min-width:130px');
		var ordI = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'style': 'width:4em', 'value': (g.order != null ? g.order : 100) });
		var del = E('button', { 'class': 'cbi-button cbi-button-remove', 'click': function() { syncGeorules(); state.georules.splice(idx, 1); renderAll(); } }, _('Delete'));
		grEls.push({ name: nameI, enabled: enI, domain: domI, ip: ipI, source: srcI, network: netS, exit: exitS, order: ordI });
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, enI),
			E('td', { 'class': 'td' }, nameI),
			E('td', { 'class': 'td' }, domI),
			E('td', { 'class': 'td' }, ipI),
			E('td', { 'class': 'td' }, srcI),
			E('td', { 'class': 'td' }, netS),
			E('td', { 'class': 'td' }, exitS),
			E('td', { 'class': 'td' }, ordI),
			E('td', { 'class': 'td' }, del)
		]));
	});
	if (!state.georules.length)
		rows.push(E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'colspan': 9 }, E('em', {}, _('No custom rules.'))) ]));

	var addBtn = E('button', { 'class': 'cbi-button cbi-button-add', 'click': function() {
		syncGeorules();
		state.georules.push({ name: '', enabled: true, domain: [], ip: [], source: [], network: '', exit: 'direct', order: 100 });
		renderAll();
	} }, _('+ Add rule'));
	var saveBtn = E('button', { 'class': 'cbi-button cbi-button-save important', 'click': function() { saveGeorules(saveBtn); } }, _('Save rules & apply'));

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, _('Custom geo-rules')),
		E('table', { 'class': 'table' }, rows),
		E('div', { 'style': 'margin:.6em 0;display:flex;gap:8px' }, [ addBtn, saveBtn ]),
		E('div', { 'style': 'color:#888;font-size:90%' }, [
			E('p', {}, _('Fields within one rule are AND-ed (xray semantics). Matchers accept geosite:/geoip:/domain:/full:/keyword:/regexp: and plain domains/CIDRs. Rules are applied in ascending order, after lists, before the registry rule.'))
		])
	]);
}

function saveGeorules(btn) {
	syncGeorules();
	var seen = {};
	for (var i = 0; i < state.georules.length; i++) {
		var g = state.georules[i];
		if (!/^[A-Za-z0-9_-]{1,32}$/.test(g.name))
			return ui.addNotification(null, E('p', {}, _('Invalid rule name: ') + (g.name || '(empty)')), 'error');
		if (seen[g.name]) return ui.addNotification(null, E('p', {}, _('Duplicate rule name: ') + g.name), 'error');
		seen[g.name] = 1;
		if (!g.domain.length && !g.ip.length && !g.source.length)
			return ui.addNotification(null, E('p', {}, _('Rule ') + g.name + _(' has no matchers')), 'error');
	}
	if (state.managed && !confirm(_('Apply rules and restart xray now?'))) return;
	btn.disabled = true;
	var payload = state.georules.map(function(g) {
		return { name: g.name, enabled: g.enabled ? '1' : '0', order: parseInt(g.order, 10) || 100,
		         domain: g.domain, ip: g.ip, source: g.source, network: g.network, exit: g.exit };
	});
	callGeorules(payload).then(function(res) {
		btn.disabled = false;
		if (res && res.ok) { ui.addNotification(null, E('p', {}, res.msg || _('Saved.')), 'info'); return refresh(); }
		ui.addNotification(null, E('p', {}, _('Save failed. ') + ((res && res.msg) || '')), 'error');
	}, function() { btn.disabled = false; ui.addNotification(null, E('p', {}, _('Save call failed.')), 'error'); });
}

function renderAll() {
	var content = [];
	if (!state.managed)
		content.push(E('div', { 'class': 'alert-message warning' },
			_('Managed routing is OFF — edits are saved but not applied to xray until migration enables it.')));
	if (state.warnings && state.warnings.length)
		content.push(E('div', { 'class': 'alert-message warning' }, [
			E('strong', {}, _('Routing warnings:')),
			E('ul', {}, state.warnings.map(function(w) { return E('li', {}, w); }))
		]));
	content.push(renderFwPanel(), renderGlobals(), renderGeorules());
	while (root.firstChild) root.removeChild(root.firstChild);
	content.forEach(function(n) { if (n) root.appendChild(n); });
}

function refresh() {
	return Promise.all([ callGet(), callFwGet().catch(function() { return {}; }) ]).then(function(rs) {
		var r = rs[0] || {};
		state.exits = r.exits || [];
		state.managed = !!r.managed;
		state.tproxy_port = r.tproxy_port || 1200;
		state.default_exit = r.default_exit || 'direct';
		state.registry = r.registry || { enabled: false, exit: '', geosite: '', geoip: '' };
		state.georules = (r.georules || []).map(function(g) {
			return { name: g.name, enabled: g.enabled, order: g.order, domain: g.domain || [],
			         ip: g.ip || [], source: g.source || [], network: g.network || '', exit: g.exit };
		});
		state.geodata_present = !!r.geodata_present;
		state.warnings = r.warnings || [];
		fw = rs[1] || {};
		renderAll();
	});
}

return view.extend({
	load: function() { return refresh().catch(function() {}); },
	render: function() {
		root = E('div', {});
		renderAll();
		poll.add(function() { return callFwGet().then(function(s) { fw = s || {}; renderAll(); }); }, 10);
		return E('div', {}, [ E('h2', {}, _('Xray Routing')), root ]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
