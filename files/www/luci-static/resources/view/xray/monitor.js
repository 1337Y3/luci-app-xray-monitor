'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var callStatus    = rpc.declare({ object: 'xray-monitor', method: 'status' });
var callStats     = rpc.declare({ object: 'xray-monitor', method: 'stats' });
var callOutbounds = rpc.declare({ object: 'xray-monitor', method: 'outbounds' });
var callReset     = rpc.declare({ object: 'xray-monitor', method: 'reset' });
var callEnableApi = rpc.declare({ object: 'xray-monitor', method: 'enable_api' });
var callValidate  = rpc.declare({ object: 'xray-monitor', method: 'validate' });
var callUpdChk    = rpc.declare({ object: 'xray-monitor', method: 'update_check' });
var callUpdApply  = rpc.declare({ object: 'xray-monitor', method: 'update_apply' });

var prev = null;  /* { ts, flat } for rate calculation */
var root = null;  /* container element to redraw into */
var state = {
	status: {},
	parsed: { data: { inbound: {}, outbound: {} }, flat: {} },
	rates: {},      /* "kind/name/dir" -> bytes/s */
	health: {},     /* tag -> { up, ms, active } */
	apiOk: null     /* derived from whether stats returned data */
};

function fmtBytes(n) {
	n = Number(n) || 0;
	var u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'], i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return (i ? n.toFixed(2) : n.toFixed(0)) + ' ' + u[i];
}

function fmtRate(k, name, dir) {
	var v = state.rates[k + '/' + name + '/' + dir];
	return (v === undefined) ? '–' : fmtBytes(v) + '/s';
}

function fmtUptime(s) {
	s = Number(s) || 0;
	var d = Math.floor(s / 86400); s -= d * 86400;
	var h = Math.floor(s / 3600);  s -= h * 3600;
	var m = Math.floor(s / 60);
	var out = [];
	if (d) out.push(d + 'd');
	if (d || h) out.push(h + 'h');
	out.push(m + 'm');
	return out.join(' ');
}

function parseStats(reply) {
	var stat = (reply && reply.stat) ? reply.stat : [];
	var data = { inbound: {}, outbound: {} }, flat = {};
	for (var i = 0; i < stat.length; i++) {
		var parts = String(stat[i].name || '').split('>>>');
		if (parts.length !== 4) continue;
		var kind = parts[0], name = parts[1], dir = parts[3];
		var val = Number(stat[i].value || 0);
		if (!data[kind]) continue;
		if (!data[kind][name]) data[kind][name] = { up: 0, down: 0 };
		if (dir === 'uplink')   data[kind][name].up = val;
		if (dir === 'downlink') data[kind][name].down = val;
		flat[kind + '/' + name + '/' + dir] = val;
	}
	return { data: data, flat: flat };
}

function statusCell(tag) {
	var h = state.health[tag];
	if (!h) return E('span', { 'style': 'color:#888' }, '–');
	var color, label;
	if (h.up === 1)      { color = '#46a546'; label = 'connected' + (h.ms > 0 ? ' · ' + h.ms + ' ms' : ''); }
	else if (h.up === 0) { color = '#cc3300'; label = 'down'; }
	else                 { color = '#888';    label = 'unknown'; }
	var els = [
		E('span', { 'style': 'color:' + color + ';font-weight:bold;' }, '● '),
		E('span', {}, label)
	];
	if (h.active)
		els.push(E('span', { 'style': 'margin-left:6px;color:#46a546;font-size:85%;' }, '(live)'));
	return E('span', {}, els);
}

function buildTable(title, kind, withStatus) {
	var group = state.parsed.data[kind] || {};
	var names = Object.keys(group).sort();

	var head = [
		E('th', { 'class': 'th' }, _('Tag')),
		E('th', { 'class': 'th right' }, _('Upload')),
		E('th', { 'class': 'th right' }, _('Download')),
		E('th', { 'class': 'th right' }, '↑ ' + _('rate')),
		E('th', { 'class': 'th right' }, '↓ ' + _('rate'))
	];
	if (withStatus) head.push(E('th', { 'class': 'th' }, _('Status')));
	var rows = [ E('tr', { 'class': 'tr table-titles' }, head) ];

	if (!names.length)
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': withStatus ? 6 : 5 }, E('em', {}, _('No data')))
		]));

	names.forEach(function(name) {
		var cells = [
			E('td', { 'class': 'td' }, E('strong', {}, name)),
			E('td', { 'class': 'td right' }, fmtBytes(group[name].up)),
			E('td', { 'class': 'td right' }, fmtBytes(group[name].down)),
			E('td', { 'class': 'td right' }, fmtRate(kind, name, 'uplink')),
			E('td', { 'class': 'td right' }, fmtRate(kind, name, 'downlink'))
		];
		if (withStatus) cells.push(E('td', { 'class': 'td' }, statusCell(name)));
		rows.push(E('tr', { 'class': 'tr' }, cells));
	});

	return E('div', {}, [ E('h3', {}, title), E('table', { 'class': 'table' }, rows) ]);
}

function buildStatusCard() {
	var s = state.status || {};
	var running = !!s.running;
	var badge = E('span', {
		'style': 'background:' + (running ? '#46a546' : '#cc3300') +
		         ';color:#fff;padding:2px 10px;border-radius:3px;font-weight:bold;'
	}, running ? _('running') : _('stopped'));
	function row(k, v) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '33%' }, E('strong', {}, k)),
			E('td', { 'class': 'td left' }, v)
		]);
	}
	return E('div', {}, [
		E('h3', {}, _('Service')),
		E('table', { 'class': 'table' }, [
			row(_('Status'), badge),
			row(_('PID'), s.pid ? String(s.pid) : '–'),
			row(_('Uptime'), running ? fmtUptime(s.uptime) : '–'),
			row(_('Version'), s.version || '–')
		])
	]);
}

function apiBanner() {
	var s = state.status || {};
	if (!s.running || state.apiOk !== false) return null;
	var btn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Enable Stats API'));
	btn.addEventListener('click', function() {
		btn.disabled = true;
		callEnableApi().then(function(res) {
			btn.disabled = false;
			if (res && res.ok) ui.addNotification(null, E('p', _('Stats API enabled: ') + (res.msg || '')), 'info');
			else ui.addNotification(null, E('p', _('Could not enable Stats API: ') + ((res && res.msg) || _('unknown error'))), 'error');
			return refreshStats();
		}, function() { btn.disabled = false; ui.addNotification(null, E('p', _('Enable call failed.')), 'error'); });
	});
	return E('div', {
		'style': 'margin:.5em 0;padding:10px;border-radius:6px;background:#fdf0d5;border:1px solid #e0b34a;color:#222;' +
		         'display:flex;align-items:center;gap:12px;flex-wrap:wrap;'
	}, [
		E('span', {}, _('Xray is running but the Stats API was not detected on 127.0.0.1:10085 — monitoring needs it.')),
		btn
	]);
}

function redraw() {
	if (!root) return;
	var content = [
		apiBanner(),
		buildStatusCard(),
		buildTable(_('Outbounds (VPS exits)'), 'outbound', true),
		buildTable(_('Inbounds (tproxy)'), 'inbound', false),
		E('div', { 'style': 'margin-top:1em;color:#888;font-size:90%;' },
			_('Traffic auto-refreshes every 5s; connectivity every 30s. Counters are cumulative since the last xray restart.'))
	];
	while (root.firstChild) root.removeChild(root.firstChild);
	content.forEach(function(n) { if (n) root.appendChild(n); });
}

function refreshStats() {
	return Promise.all([ callStatus(), callStats() ]).then(function(r) {
		state.status = r[0] || {};
		var parsed = parseStats(r[1]);
		var now = Date.now();
		var dt = prev ? (now - prev.ts) / 1000 : 0;
		var rates = {};
		if (prev && dt > 0)
			Object.keys(parsed.flat).forEach(function(k) {
				var pv = prev.flat[k];
				if (pv !== undefined) rates[k] = Math.max(0, (parsed.flat[k] - pv) / dt);
			});
		state.parsed = parsed;
		state.rates = rates;
		state.apiOk = (Object.keys(parsed.flat).length > 0);
		prev = { ts: now, flat: parsed.flat };
		redraw();
	});
}

function refreshHealth() {
	return callOutbounds().then(function(r) {
		var h = {};
		((r && r.outbounds) || []).forEach(function(o) { h[o.tag] = o; });
		state.health = h;
		redraw();
	});
}

return view.extend({
	load: function() {
		return refreshStats().catch(function() {});
	},

	render: function() {
		root = E('div', { 'class': 'cbi-section' });
		redraw();
		poll.add(refreshStats, 5);
		poll.add(refreshHealth, 30);
		refreshHealth();   // populate connectivity async; never blocks first paint

		var resetBtn = E('button', {
			'class': 'cbi-button cbi-button-negative',
			'click': function(ev) {
				if (!confirm(_('Reset all Xray traffic counters to zero?'))) return;
				var btn = ev.target;
				btn.disabled = true;
				callReset()
					.then(function() { prev = null; return refreshStats(); })
					.then(function() { btn.disabled = false; },
					      function() { btn.disabled = false; });
			}
		}, _('Reset counters'));

		var validateBtn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Validate config'));
		validateBtn.addEventListener('click', function() {
			validateBtn.disabled = true;
			callValidate().then(function(res) {
				validateBtn.disabled = false;
				if (res && res.ok)
					ui.addNotification(null, E('p', _('xray -test: ') + (res.msg || 'OK')), 'info');
				else
					ui.addNotification(null, E('p', [ E('strong', {}, _('xray -test failed: ')), document.createTextNode((res && res.msg) || _('unknown error')) ]), 'error');
			}, function() { validateBtn.disabled = false; ui.addNotification(null, E('p', _('Validate call failed.')), 'error'); });
		});

		var updBtn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Check for updates'));
		updBtn.addEventListener('click', function() {
			updBtn.disabled = true;
			callUpdChk().then(function(res) {
				updBtn.disabled = false;
				if (!res || !res.latest) {
					ui.addNotification(null, E('p', _('Could not reach the update feed (installed: ') + ((res && res.installed) || '?') + ').'), 'warning');
					return;
				}
				if (!res.update_available) {
					ui.addNotification(null, E('p', _('Up to date (') + res.installed + ').'), 'info');
					return;
				}
				if (!confirm(_('Update available: ') + res.installed + ' → ' + res.latest + _('.\nDownload and install now? xray will restart.'))) return;
				callUpdApply().then(function(r) {
					ui.addNotification(null, E('p', (r && r.msg) || _('Update started.')), 'info');
					// recheck after the detached update + rpcd restart settle
					window.setTimeout(function() { location.reload(); }, 15000);
				}, function() { ui.addNotification(null, E('p', _('Update call failed.')), 'error'); });
			}, function() { updBtn.disabled = false; ui.addNotification(null, E('p', _('Update check failed.')), 'error'); });
		});

		var bar = E('div', { 'style': 'margin:.5em 0;display:flex;gap:8px;flex-wrap:wrap;' }, [ updBtn, validateBtn, resetBtn ]);
		return E('div', {}, [ E('h2', {}, _('Xray Monitor')), bar, root ]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
