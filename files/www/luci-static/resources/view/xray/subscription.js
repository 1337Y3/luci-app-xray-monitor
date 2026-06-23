'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var callGet    = rpc.declare({ object: 'xray-monitor', method: 'sub_get' });
var callFetch  = rpc.declare({ object: 'xray-monitor', method: 'sub_fetch' });
var callApply  = rpc.declare({ object: 'xray-monitor', method: 'sub_apply' });
var callSetCfg = rpc.declare({ object: 'xray-monitor', method: 'sub_setcfg',
                               params: [ 'url', 'cron', 'cron_schedule', 'auto_apply', 'user_agent' ] });

var SCHEDS = [
	[ '*/15 * * * *', 'Every 15 minutes' ],
	[ '*/30 * * * *', 'Every 30 minutes' ],
	[ '0 * * * *',    'Hourly' ],
	[ '0 */6 * * *',  'Every 6 hours' ],
	[ '0 */12 * * *', 'Every 12 hours' ],
	[ '0 4 * * *',    'Daily at 04:00' ]
];

var root = null;
var state = { has_url: false, url_masked: '', last_fetch: 0, status: 'never', pending: false,
              cron: true, cron_schedule: '0 * * * *', auto_apply: false,
              diff: { added: [], removed: [], changed: [], total: 0 }, servers: [] };

function fmtAgo(epoch) {
	epoch = Number(epoch) || 0;
	if (!epoch) return _('never');
	var s = Math.max(0, Math.floor(Date.now() / 1000) - epoch);
	if (s < 60) return s + 's ' + _('ago');
	if (s < 3600) return Math.floor(s / 60) + 'm ' + _('ago');
	if (s < 86400) return Math.floor(s / 3600) + 'h ' + _('ago');
	return Math.floor(s / 86400) + 'd ' + _('ago');
}

function statusBadge(st) {
	var map = {
		ok: ['#46a546', _('fetched OK')], applied: ['#46a546', _('applied')],
		never: ['#888', _('never fetched')], 'no-url': ['#cc7a00', _('no URL set')],
		'fetch-error': ['#cc3300', _('fetch error')], 'parse-error': ['#cc3300', _('parse error')],
		'test-failed': ['#cc3300', _('config test failed')]
	};
	var m = map[st] || ['#888', st];
	return E('span', { 'style': 'background:' + m[0] + ';color:#fff;padding:2px 8px;border-radius:3px;' }, m[1]);
}

function tagList(arr, color) {
	if (!arr || !arr.length) return E('span', { 'style': 'color:#888' }, '—');
	return E('span', {}, arr.map(function(t) {
		return E('span', { 'style': 'display:inline-block;margin:1px 3px;padding:1px 6px;border-radius:3px;background:' + color + ';color:#fff;font-size:90%;' }, t);
	}));
}

function busy(btn, p) {
	btn.disabled = true;
	var done = function() { btn.disabled = false; };
	return p.then(function(v) { done(); return v; }, function(e) { done(); throw e; });
}

function refresh() {
	return callGet().then(function(r) { if (r && typeof r == 'object') state = r; redraw(); });
}

function row(k, v) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '28%' }, E('strong', {}, k)),
		E('td', { 'class': 'td left' }, v)
	]);
}

function buildSettings() {
	var urlInput = E('input', {
		'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%;max-width:540px;',
		'placeholder': state.has_url ? (state.url_masked + '  (leave blank to keep)') : 'https://panel.example.com/sub/<token>'
	});

	var schedInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:160px', 'value': state.cron_schedule });
	var presetOpts = [ E('option', { 'value': '' }, _('Custom…')) ];
	var matched = false;
	SCHEDS.forEach(function(p) {
		var sel = (p[0] == state.cron_schedule);
		if (sel) matched = true;
		presetOpts.push(E('option', { 'value': p[0], 'selected': sel ? '' : null }, _(p[1])));
	});
	if (!matched) presetOpts[0].selected = true;
	var preset = E('select', { 'class': 'cbi-input-select' }, presetOpts);
	preset.addEventListener('change', function() { if (preset.value) schedInput.value = preset.value; });

	var cronChk = E('input', { 'type': 'checkbox', 'checked': state.cron ? '' : null });
	var autoChk = E('input', { 'type': 'checkbox', 'checked': state.auto_apply ? '' : null });

	var saveBtn = E('button', { 'class': 'cbi-button cbi-button-save' }, _('Save settings'));
	saveBtn.addEventListener('click', function() {
		var url = (urlInput.value || '').trim();
		var sched = (schedInput.value || '').trim();
		if (url && !/^https?:\/\//.test(url))
			return ui.addNotification(null, E('p', _('Enter a valid http(s) URL')), 'warning');
		if (sched.split(/\s+/).filter(Boolean).length !== 5)
			return ui.addNotification(null, E('p', _('Cron schedule must have 5 fields (e.g. 0 * * * *)')), 'warning');
		busy(saveBtn, callSetCfg(url, cronChk.checked ? '1' : '0', sched, autoChk.checked ? '1' : '0', '')
			.then(function(res) {
				if (res && res.ok) ui.addNotification(null, E('p', _('Settings saved.')), 'info');
				else ui.addNotification(null, E('p', _('Save failed: ') + ((res && res.msg) || '')), 'error');
				return refresh();
			}));
	});

	return E('table', { 'class': 'table' }, [
		row(_('Subscription URL'), E('div', {}, [
			state.has_url ? E('code', { 'style': 'display:block;margin-bottom:3px;' }, state.url_masked)
			              : E('em', { 'style': 'color:#cc7a00' }, _('not set — paste your Remnawave URL below')),
			urlInput
		])),
		row(_('Scheduled fetch'), E('label', { 'style': 'display:inline-flex;gap:6px;align-items:center;' }, [ cronChk, E('span', {}, _('Periodically fetch the subscription')) ])),
		row(_('Schedule'), E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap;align-items:center;' }, [ preset, schedInput, E('span', { 'style': 'color:#888;font-size:90%;' }, _('(cron expression)')) ])),
		row(_('Auto-apply updates'), E('label', { 'style': 'display:inline-flex;gap:6px;align-items:center;' }, [ autoChk, E('span', {}, _('On fetch, apply changes and restart xray automatically')) ])),
		row('', saveBtn)
	]);
}

function redraw() {
	if (!root) return;

	var fetchBtn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Fetch now'));
	fetchBtn.addEventListener('click', function() { busy(fetchBtn, callFetch().then(function() { return refresh(); })); });

	var applyBtn = E('button', { 'class': 'cbi-button cbi-button-positive', 'disabled': state.pending ? null : 'disabled' }, _('Apply & restart xray'));
	applyBtn.addEventListener('click', function() {
		if (!confirm(_('Apply staged outbounds to config.json and restart xray now?'))) return;
		busy(applyBtn, callApply().then(function(res) {
			if (res && res.ok) ui.addNotification(null, E('p', _('Applied and restarted xray.')), 'info');
			else ui.addNotification(null, E('p', _('Apply failed — config test did not pass; nothing changed.')), 'error');
			return refresh();
		}));
	});

	var statusTable = E('table', { 'class': 'table' }, [
		row(_('Last fetch'), E('span', {}, [ document.createTextNode(fmtAgo(state.last_fetch) + '  '), statusBadge(state.status) ])),
		row(_('Pending'), state.pending
			? E('span', { 'style': 'color:#cc7a00;font-weight:bold;' }, _('changes staged — not yet applied'))
			: E('span', { 'style': 'color:#46a546;' }, _('config up to date'))),
		row(_('Auto-apply'), state.auto_apply
			? E('span', { 'style': 'color:#cc7a00;' }, _('ON — fetches apply automatically'))
			: E('span', { 'style': 'color:#888;' }, _('off')))
	]);

	var diffBox = state.pending ? E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'width': '28%' }, _('Added')),   E('td', { 'class': 'td' }, tagList(state.diff.added, '#46a546')) ]),
		E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td' }, _('Changed')), E('td', { 'class': 'td' }, tagList(state.diff.changed, '#cc7a00')) ]),
		E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td' }, _('Removed')), E('td', { 'class': 'td' }, tagList(state.diff.removed, '#cc3300')) ])
	]) : null;

	var rows = [ E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('Tag')), E('th', { 'class': 'th' }, _('Address')),
		E('th', { 'class': 'th' }, _('Network')), E('th', { 'class': 'th' }, _('Mode')), E('th', { 'class': 'th' }, _('SNI'))
	]) ];
	if (!state.servers.length)
		rows.push(E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'colspan': 5 }, E('em', {}, _('No servers installed yet — set a URL, Fetch, then Apply.'))) ]));
	state.servers.forEach(function(s) {
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, E('strong', {}, s.tag)),
			E('td', { 'class': 'td' }, s.address + ':' + s.port),
			E('td', { 'class': 'td' }, s.network || '—'),
			E('td', { 'class': 'td' }, s.mode || '—'),
			E('td', { 'class': 'td' }, s.sni || '—')
		]));
	});

	var content = [
		E('h3', {}, _('Settings')),
		buildSettings(),
		E('h3', {}, _('Status')),
		statusTable,
		E('div', { 'style': 'margin:.6em 0;display:flex;gap:8px;' }, [ fetchBtn, applyBtn ]),
		(diffBox ? E('div', {}, [ E('h3', {}, _('Pending changes')), diffBox ]) : E('div', {})),
		E('h3', {}, _('Installed servers')),
		E('table', { 'class': 'table' }, rows),
		E('div', { 'style': 'margin-top:1em;color:#888;font-size:90%;' },
			_('The scheduled fetch stages updates. With Auto-apply off they apply only when you click Apply & restart (backup + xray -test + auto-rollback). With Auto-apply on, a fetch that finds changes applies and restarts xray automatically.'))
	];

	while (root.firstChild) root.removeChild(root.firstChild);
	content.forEach(function(n) { root.appendChild(n); });
}

return view.extend({
	load: function() { return refresh().catch(function() {}); },
	render: function() {
		root = E('div', { 'class': 'cbi-section' });
		redraw();
		poll.add(refresh, 15);
		return E('div', {}, [ E('h2', {}, _('Xray Subscription')), root ]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
