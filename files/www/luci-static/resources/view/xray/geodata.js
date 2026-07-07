'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var callGet      = rpc.declare({ object: 'xray-monitor', method: 'geodat_get' });
var callUpdate   = rpc.declare({ object: 'xray-monitor', method: 'geodat_update' });
var callSetCfg   = rpc.declare({ object: 'xray-monitor', method: 'geodat_setcfg', params: [ 'enabled', 'cron', 'cron_schedule', 'source_url' ] });
var callRollback = rpc.declare({ object: 'xray-monitor', method: 'geodat_rollback' });

var SCHEDS = [
	[ '0 5 * * *', 'Daily at 05:00' ],
	[ '0 5 * * 1,4', 'Mon & Thu at 05:00' ],
	[ '0 5 * * 0', 'Weekly (Sun 05:00)' ],
	[ '0 */12 * * *', 'Every 12 hours' ]
];

var root = null;
var state = { enabled: true, cron: true, cron_schedule: '0 5 * * 1,4', source_url: '', datadir: '',
              running: false, files: [], last: null };
var cfgEls = {};

function fmtBytes(n) {
	n = Number(n) || 0;
	var u = ['B', 'KB', 'MB', 'GB'], i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return (i ? n.toFixed(1) : n.toFixed(0)) + ' ' + u[i];
}
function fmtAgo(e) {
	e = Number(e) || 0; if (!e) return _('never');
	var s = Math.max(0, Math.floor(Date.now() / 1000) - e);
	if (s < 60) return s + 's ' + _('ago');
	if (s < 3600) return Math.floor(s / 60) + 'm ' + _('ago');
	if (s < 86400) return Math.floor(s / 3600) + 'h ' + _('ago');
	return Math.floor(s / 86400) + 'd ' + _('ago');
}
function resultColor(r) {
	if (r == 'ok') return '#46a546';
	if (r == 'checksum-error' || r == 'test-failed' || r == 'rolled-back') return '#cc3300';
	return '#888';
}

function fileCard(f) {
	return E('div', { 'style': 'border:1px solid #ddd;border-radius:6px;padding:10px;min-width:210px' }, [
		E('div', { 'style': 'font-weight:bold' }, f.name),
		f.present
			? E('div', { 'style': 'color:#888;font-size:90%' }, [
				E('div', {}, fmtBytes(f.size)),
				E('div', {}, _('updated ') + fmtAgo(f.mtime)),
				f.prev ? E('div', { 'style': 'color:#46a546' }, _('previous version kept')) : null
			])
			: E('div', { 'style': 'color:#cc3300' }, _('not installed'))
	]);
}

function renderAll() {
	cfgEls = {};
	var anyPrev = state.files.some(function(f) { return f.prev; });

	var updateBtn = E('button', {
		'class': 'cbi-button cbi-button-action important',
		'disabled': state.running ? '' : null,
		'click': function() {
			callUpdate().then(function() {
				ui.addNotification(null, E('p', {}, _('Update started.')), 'info');
				state.running = true; renderAll();
			});
		}
	}, state.running ? _('Updating…') : _('Update now'));

	var rollbackBtn = E('button', {
		'class': 'cbi-button cbi-button-neutral', 'disabled': anyPrev ? null : '',
		'click': function() {
			if (!confirm(_('Roll back to the previous geodata and restart xray?'))) return;
			callRollback().then(function(res) {
				ui.addNotification(null, E('p', {}, (res && res.msg) || _('Rolled back.')), (res && res.ok) ? 'info' : 'error');
				refresh();
			});
		}
	}, _('Roll back'));

	var last = state.last || {};
	var lastLine = last.ts
		? E('div', { 'style': 'margin:.4em 0' }, [
			_('Last update: '),
			E('span', { 'style': 'color:' + resultColor(last.result) }, (last.result || '?')),
			' · ' + fmtAgo(last.ts),
			(last.via_proxy ? E('span', { 'style': 'color:#888' }, ' · ' + _('via proxy')) : null),
			last.msg ? E('div', { 'style': 'color:#888;font-size:90%' }, last.msg) : null
		])
		: E('div', { 'style': 'color:#888;margin:.4em 0' }, _('No update has run yet.'));

	// config form
	cfgEls.enabled = E('input', { 'type': 'checkbox' }); cfgEls.enabled.checked = state.cron && state.enabled;
	var schedOpts = SCHEDS.map(function(p) { return E('option', { 'value': p[0], 'selected': (p[0] == state.cron_schedule) ? '' : null }, p[1]); });
	if (!SCHEDS.some(function(p) { return p[0] == state.cron_schedule; }))
		schedOpts.unshift(E('option', { 'value': state.cron_schedule, 'selected': '' }, state.cron_schedule + ' ' + _('(custom)')));
	cfgEls.schedule = E('select', { 'class': 'cbi-input-select' }, schedOpts);
	cfgEls.url = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%;max-width:640px', 'value': state.source_url || '' });

	var saveCfg = E('button', { 'class': 'cbi-button cbi-button-save', 'click': function() { saveCfg2(saveCfg); } }, _('Save schedule'));

	function row(label, ctl) {
		return E('div', { 'style': 'display:flex;gap:10px;align-items:center;margin:.3em 0' }, [
			E('label', { 'style': 'min-width:12em' }, label), ctl ]);
	}

	var content = [
		E('h3', {}, _('Geodata files (geoip.dat / geosite.dat)')),
		E('div', { 'style': 'color:#888;font-size:90%;margin-bottom:.4em' }, [ _('Asset directory: '), E('code', {}, state.datadir || '/usr/share/xray') ]),
		E('div', { 'style': 'display:flex;gap:12px;flex-wrap:wrap;margin:.5em 0' }, state.files.map(fileCard)),
		lastLine,
		E('div', { 'style': 'display:flex;gap:8px;margin:.6em 0' }, [ updateBtn, rollbackBtn ]),
		E('h3', { 'style': 'margin-top:1em' }, _('Auto-update')),
		row(_('Scheduled updates'), cfgEls.enabled),
		row(_('Schedule'), cfgEls.schedule),
		row(_('Source base URL'), cfgEls.url),
		E('div', { 'style': 'margin:.5em 0' }, saveCfg),
		E('div', { 'style': 'color:#888;font-size:90%' }, [
			E('p', {}, _('Each update compares the published checksum first and only downloads + restarts xray when the data actually changed. A staged xray -test validates every geosite/geoip tag before cutover, and the previous files are kept for one-click rollback.'))
		])
	];
	while (root.firstChild) root.removeChild(root.firstChild);
	content.forEach(function(n) { if (n) root.appendChild(n); });
}

function saveCfg2(btn) {
	var url = cfgEls.url.value.trim();
	if (url && !/^https?:\/\//.test(url))
		return ui.addNotification(null, E('p', {}, _('Invalid URL')), 'error');
	btn.disabled = true;
	var en = cfgEls.enabled.checked ? '1' : '0';
	callSetCfg(en, en, cfgEls.schedule.value, url).then(function(res) {
		btn.disabled = false;
		if (res && res.ok) { ui.addNotification(null, E('p', {}, _('Saved.')), 'info'); return refresh(); }
		ui.addNotification(null, E('p', {}, _('Save failed. ') + ((res && res.msg) || '')), 'error');
	}, function() { btn.disabled = false; ui.addNotification(null, E('p', {}, _('Save call failed.')), 'error'); });
}

function refresh() {
	return callGet().then(function(r) {
		r = r || {};
		state.enabled = (r.enabled != 0);
		state.cron = (r.cron != 0);
		state.cron_schedule = r.cron_schedule || '0 5 * * 1,4';
		state.source_url = r.source_url || '';
		state.datadir = r.datadir || '';
		state.running = !!r.running;
		state.files = r.files || [];
		state.last = r.last || null;
		renderAll();
	});
}

return view.extend({
	load: function() { return refresh().catch(function() {}); },
	render: function() {
		root = E('div', { 'class': 'cbi-section' });
		renderAll();
		// while an update runs, poll faster so the card flips when it finishes
		poll.add(function() {
			return callGet().then(function(r) {
				r = r || {};
				var was = state.running;
				state.running = !!r.running;
				state.files = r.files || state.files;
				state.last = r.last || state.last;
				if (was || state.running || !root.childNodes.length) renderAll();
			});
		}, 5);
		return E('div', {}, [ E('h2', {}, _('Xray Geodata')), root ]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
