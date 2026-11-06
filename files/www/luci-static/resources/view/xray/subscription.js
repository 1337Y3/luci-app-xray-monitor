'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require xray-diff as XrayDiff';

var callGet    = rpc.declare({ object: 'xray-monitor', method: 'sub_get' });
var callFetch  = rpc.declare({ object: 'xray-monitor', method: 'sub_fetch' });
var callApply  = rpc.declare({ object: 'xray-monitor', method: 'sub_apply' });
var callSetCfg = rpc.declare({ object: 'xray-monitor', method: 'sub_setcfg', params: [ 'cron', 'cron_schedule', 'auto_apply', 'user_agent', 'hot_swap' ] });
var callAdd    = rpc.declare({ object: 'xray-monitor', method: 'sub_add',  params: [ 'prefix', 'url' ] });
var callDel    = rpc.declare({ object: 'xray-monitor', method: 'sub_del',  params: [ 'id' ] });
var callEdit   = rpc.declare({ object: 'xray-monitor', method: 'sub_edit', params: [ 'id', 'prefix', 'url', 'enabled' ] });
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

var SCHEDS = [
	[ '*/15 * * * *', 'Every 15 minutes' ], [ '*/30 * * * *', 'Every 30 minutes' ],
	[ '0 * * * *', 'Hourly' ], [ '0 */6 * * *', 'Every 6 hours' ],
	[ '0 */12 * * *', 'Every 12 hours' ], [ '0 4 * * *', 'Daily at 04:00' ]
];

var root = null;
var state = { subscriptions: [], cron: true, cron_schedule: '0 * * * *', auto_apply: false,
              hot_swap: true, last_fetch: 0, status: 'never', pending: false, last_apply: null,
              fetch_path: '', update_path: '',
              diff: { added: [], removed: [], changed: [], total: 0 }, servers: [] };

function fmtAgo(e) {
	e = Number(e) || 0; if (!e) return _('never');
	var s = Math.max(0, Math.floor(Date.now() / 1000) - e);
	if (s < 60) return s + 's ' + _('ago');
	if (s < 3600) return Math.floor(s / 60) + 'm ' + _('ago');
	if (s < 86400) return Math.floor(s / 3600) + 'h ' + _('ago');
	return Math.floor(s / 86400) + 'd ' + _('ago');
}
function fmtBytes(n) {
	n = Number(n) || 0;
	var u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'], i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return (i ? n.toFixed(2) : n.toFixed(0)) + ' ' + u[i];
}
function fmtExpire(ts) {
	ts = Number(ts) || 0;
	if (!ts) return { text: _('never'), color: '#888' };
	var date = new Date(ts * 1000).toISOString().slice(0, 10);
	var left = ts - Math.floor(Date.now() / 1000);
	if (left <= 0) return { text: _('expired') + ' · ' + date, color: '#cc3300' };
	var days = Math.floor(left / 86400);
	var when = days >= 1 ? (days + 'd') : (Math.floor(left / 3600) + 'h');
	return { text: date + ' · ' + when + ' ' + _('left'),
	         color: days <= 3 ? '#cc3300' : (days <= 7 ? '#cc7a00' : '#46a546') };
}
function decodeTitle(t) {
	if (!t) return '';
	if (t.indexOf('base64:') !== 0) return t;
	try {
		return decodeURIComponent(Array.prototype.map.call(atob(t.slice(7)), function(c) {
			return '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2);
		}).join(''));
	} catch (e) { return ''; }
}
function statusBadge(st, la) {
	var m = ({ ok: ['#46a546', _('fetched OK')], applied: ['#46a546', _('applied')],
		partial: ['#cc7a00', _('partial — some failed')], never: ['#888', _('never fetched')],
		'no-subs': ['#888', _('no subscriptions')], 'fetch-error': ['#cc3300', _('fetch error')],
		'test-failed': ['#cc3300', _('config test failed')],
		'merge-failed': ['#cc3300', _('staged merge failed')],
		'install-failed': ['#cc3300', _('config install failed')],
		'fetched-apply-failed': ['#cc3300', _('fetched — apply failed, changes stay staged')],
		'rolled-back': ['#cc3300', _('applied but rolled back — xray unhealthy')] })[st] || ['#888', st];
	// "rolled-back" has two faces: the classic restart failed its health check
	// (xray unhealthy) - or a live apply failed and was rolled back (xray runs
	// the PREVIOUS config and is healthy; last-apply says which one it was).
	if (st == 'rolled-back' && la && la.fallback)
		m = ['#cc3300', _('live apply failed — restored the previous config')];
	return E('span', { 'style': 'background:' + m[0] + ';color:#fff;padding:2px 8px;border-radius:3px;' }, m[1]);
}
function tagList(a, c) {
	if (!a || !a.length) return E('span', { 'style': 'color:#888' }, '—');
	return E('span', {}, a.map(function(t) { return E('span', { 'style': 'display:inline-block;margin:1px 3px;padding:1px 6px;border-radius:3px;background:' + c + ';color:#fff;font-size:90%;' }, t); }));
}
// How the last apply hit the running xray (xray-sub writes last-apply.json):
// live = applied via the xray API without a restart; restart = classic
// pipeline, optionally with the reason a live apply was not possible, or the
// fallback note when a live attempt failed and was rolled back.
var APPLY_REASONS = {
	'changes-beyond-outbounds': _('changes beyond outbound membership'),
	'tag-charset': _('an outbound tag cannot be applied live (letters, digits, . _ - only)'),
	'default-outbound': _('the default outbound would change'),
	'api-unavailable': _('xray handler API not available'),
	'running-state-mismatch': _('running outbounds differ from config.json'),
	'plan-unavailable': _('hot-swap plan could not be computed')
};
function applyBadge(la) {
	if (!la || !la.ts) return null;
	var txt, col;
	if (la.mode == 'live') {
		col = '#46a546';
		txt = _('applied live (hot-swap)');
		if (la.removed || la.added) txt += ' · -' + (Number(la.removed) || 0) + '/+' + (Number(la.added) || 0);
	}
	else if (la.fallback) {
		col = '#cc3300';
		txt = _('hot-swap failed — rolled back');
	}
	else if (la.reason) {
		col = '#cc7a00';
		txt = _('restart required') + ': ' + (APPLY_REASONS[la.reason] || la.reason);
	}
	else {
		col = '#46a546';
		txt = _('applied with restart');
	}
	return E('span', { 'style': 'background:' + col + ';color:#fff;padding:2px 8px;border-radius:3px;' }, txt);
}

function pathBadge(p) {  // transport token from xray-sub: direct | via <tag> | direct, retried via <tag>
	if (!p) return E('span', { 'style': 'color:#888' }, '—');
	var proxied = p.indexOf('via') !== -1;
	return E('span', { 'style': 'font-family:monospace;background:' + (proxied ? '#4a6a9c' : '#5a5a5a') + ';color:#fff;padding:2px 8px;border-radius:3px;' }, p);
}
function busy(btn, p) { btn.disabled = true; return p.then(function(v) { btn.disabled = false; return v; }, function(e) { btn.disabled = false; throw e; }); }
function refresh() { return callGet().then(function(r) { if (r && typeof r == 'object') state = r; redraw(); }); }
function row(k, v) { return E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left', 'width': '28%' }, E('strong', {}, k)), E('td', { 'class': 'td left' }, v) ]); }
function notify(res, okMsg) {
	if (res && res.ok) ui.addNotification(null, E('p', okMsg), 'info');
	else ui.addNotification(null, E('p', [ E('strong', {}, _('Failed: ')), document.createTextNode((res && res.msg) || _('error')) ]), 'error');
	return refresh();
}
function rpcFail(e) {  // rpc-level failure (timeout, rpcd gone): still explain, then resync
	ui.addNotification(null, E('p', [ E('strong', {}, _('Failed: ')),
		document.createTextNode((e && (e.message || e.msg)) || _('error')) ]), 'error');
	return refresh();
}

function buildSubsTable() {
	var head = E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('Prefix')), E('th', { 'class': 'th' }, _('Subscription URL')),
		E('th', { 'class': 'th' }, _('Enabled')), E('th', { 'class': 'th', 'style': 'width:1%' }, '')
	]);
	var rows = [ head ];

	state.subscriptions.forEach(function(s) {
		var pfx = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:110px', 'value': s.prefix });
		var url = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%;min-width:240px',
			'placeholder': s.has_url ? (s.url_masked + '  (blank = keep)') : 'https://panel/sub/<token>' });
		var en  = E('input', { 'type': 'checkbox', 'checked': s.enabled ? '' : null });
		var save = E('button', { 'class': 'cbi-button cbi-button-save' }, _('Save'));
		var del  = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('Delete'));
		save.addEventListener('click', function() {
			var np = (pfx.value || '').trim();
			if (!/^[A-Za-z0-9_-]+$/.test(np)) return ui.addNotification(null, E('p', _('Prefix: letters/digits/-/_ only')), 'warning');
			var nu = (url.value || '').trim();
			if (nu && !/^https?:\/\//.test(nu)) return ui.addNotification(null, E('p', _('Enter a valid http(s) URL')), 'warning');
			busy(save, callEdit(s.id, np, nu, en.checked ? '1' : '0').then(function(r) { return notify(r, _('Subscription saved.')); }));
		});
		del.addEventListener('click', function() {
			if (!confirm(_('Delete subscription "') + s.prefix + _('"? (does not change config.json until you Apply)'))) return;
			busy(del, callDel(s.id).then(function(r) { return notify(r, _('Subscription deleted.')); }));
		});
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, pfx), E('td', { 'class': 'td' }, url),
			E('td', { 'class': 'td' }, en),
			E('td', { 'class': 'td', 'style': 'white-space:nowrap' }, [ save, ' ', del ])
		]));
	});

	// add row
	var apfx = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:110px', 'placeholder': 'work' });
	var aurl = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%;min-width:240px', 'placeholder': 'https://panel/sub/<token>' });
	var addb = E('button', { 'class': 'cbi-button cbi-button-add' }, _('Add'));
	addb.addEventListener('click', function() {
		var p = (apfx.value || '').trim(), u = (aurl.value || '').trim();
		if (!/^[A-Za-z0-9_-]+$/.test(p)) return ui.addNotification(null, E('p', _('Prefix: letters/digits/-/_ only')), 'warning');
		if (!/^https?:\/\//.test(u)) return ui.addNotification(null, E('p', _('Enter a valid http(s) URL')), 'warning');
		busy(addb, callAdd(p, u).then(function(r) { if (r && r.ok) { apfx.value = ''; aurl.value = ''; } return notify(r, _('Subscription added.')); }));
	});
	rows.push(E('tr', { 'class': 'tr', 'style': 'border-top:2px solid rgba(128,128,128,.3)' }, [
		E('td', { 'class': 'td' }, apfx), E('td', { 'class': 'td' }, aurl),
		E('td', { 'class': 'td' }, ''), E('td', { 'class': 'td' }, addb)
	]));
	return E('table', { 'class': 'table' }, rows);
}

function buildUsage() {
	var subs = (state.subscriptions || []).filter(function(s) { return s.usage; });
	if (!subs.length) return null;
	var rows = [ E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('Prefix')), E('th', { 'class': 'th right' }, _('Used')),
		E('th', { 'class': 'th right' }, _('Total')), E('th', { 'class': 'th', 'style': 'width:40%' }, _('Usage')),
		E('th', { 'class': 'th' }, _('Expires'))
	]) ];
	subs.forEach(function(s) {
		var u = s.usage;
		var used = (Number(u.upload) || 0) + (Number(u.download) || 0), total = Number(u.total) || 0;
		var pct = total > 0 ? Math.min(100, Math.round(used / total * 100)) : 0;
		var bcol = pct >= 90 ? '#cc3300' : (pct >= 75 ? '#cc7a00' : '#46a546');
		var meter = total > 0
			? E('div', { 'style': 'display:flex;gap:8px;align-items:center;' }, [
				E('div', { 'style': 'flex:1;background:rgba(128,128,128,.2);border-radius:4px;height:14px;overflow:hidden;' },
					E('div', { 'style': 'background:' + bcol + ';height:100%;width:' + pct + '%;' }, '')),
				E('span', { 'style': 'font-size:90%;white-space:nowrap;' }, pct + '%') ])
			: E('span', { 'style': 'color:#888;' }, _('unlimited'));
		var exp = fmtExpire(u.expire);
		var pcell = [ E('strong', {}, s.prefix) ];
		var title = decodeTitle(u.title);
		if (title) pcell.push(E('div', { 'style': 'color:#888;font-size:90%;' }, title));
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, E('div', {}, pcell)),
			E('td', { 'class': 'td right' }, fmtBytes(used)),
			E('td', { 'class': 'td right' }, total > 0 ? fmtBytes(total) : '∞'),
			E('td', { 'class': 'td' }, meter),
			E('td', { 'class': 'td', 'style': 'color:' + exp.color + ';white-space:nowrap;' }, exp.text)
		]));
	});
	return E('div', {}, [ E('h3', {}, _('Usage & expiry')), E('table', { 'class': 'table' }, rows) ]);
}

function buildSettings() {
	var schedInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:160px', 'value': state.cron_schedule });
	var opts = [ E('option', { 'value': '' }, _('Custom…')) ], matched = false;
	SCHEDS.forEach(function(p) { var sel = (p[0] == state.cron_schedule); if (sel) matched = true; opts.push(E('option', { 'value': p[0], 'selected': sel ? '' : null }, _(p[1]))); });
	if (!matched) opts[0].selected = true;
	var preset = E('select', { 'class': 'cbi-input-select' }, opts);
	preset.addEventListener('change', function() { if (preset.value) schedInput.value = preset.value; });
	var cronChk = E('input', { 'type': 'checkbox', 'checked': state.cron ? '' : null });
	var autoChk = E('input', { 'type': 'checkbox', 'checked': state.auto_apply ? '' : null });
	var hsChk = E('input', { 'type': 'checkbox', 'checked': state.hot_swap ? '' : null });
	var saveBtn = E('button', { 'class': 'cbi-button cbi-button-save' }, _('Save settings'));
	saveBtn.addEventListener('click', function() {
		var sched = (schedInput.value || '').trim();
		if (sched.split(/\s+/).filter(Boolean).length !== 5) return ui.addNotification(null, E('p', _('Cron schedule must have 5 fields')), 'warning');
		busy(saveBtn, callSetCfg(cronChk.checked ? '1' : '0', sched, autoChk.checked ? '1' : '0', '', hsChk.checked ? '1' : '0').then(function(r) { return notify(r, _('Settings saved.')); }));
	});
	return E('table', { 'class': 'table' }, [
		row(_('Scheduled fetch'), E('label', { 'style': 'display:inline-flex;gap:6px;align-items:center;' }, [ cronChk, E('span', {}, _('Periodically fetch all subscriptions')) ])),
		row(_('Schedule'), E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap;align-items:center;' }, [ preset, schedInput, E('span', { 'style': 'color:#888;font-size:90%;' }, _('(cron expression)')) ])),
		row(_('Auto-apply updates'), E('label', { 'style': 'display:inline-flex;gap:6px;align-items:center;' }, [ autoChk, E('span', {}, _('On fetch, apply changes automatically')) ])),
		row(_('Hot-swap apply'), E('label', { 'style': 'display:inline-flex;gap:6px;align-items:center;' }, [ hsChk, E('span', {}, _('Apply outbound changes live via the xray API — restart only when a change is not hot-swappable')) ])),
		row('', saveBtn)
	]);
}

function redraw() {
	if (!root) return;
	var fetchBtn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Fetch now'));
	fetchBtn.addEventListener('click', function() {
		busy(fetchBtn, callFetch().then(function(r) { return notify(r, _('Fetched.')); }, rpcFail));
	});
	var applyBtn = E('button', { 'class': 'cbi-button cbi-button-positive', 'disabled': state.pending ? null : 'disabled' }, _('Apply staged changes'));
	applyBtn.addEventListener('click', function() {
		if (!confirm(_('Apply staged outbounds to config.json now? (live via the xray API when possible, otherwise xray is restarted)'))) return;
		busy(applyBtn, callApply().then(function(r) {
			if (r && r.ok) {
				var live = (r.msg || '').indexOf('applied live') >= 0;
				return notify(r, live ? _('Applied live — xray was not restarted.') : _('Applied and restarted xray.'));
			}
			return notify(r, _('Apply failed.'));
		}, rpcFail));
	});

	var statusRows = [
		row(_('Last fetch'), E('span', {}, [ document.createTextNode(fmtAgo(state.last_fetch) + '  '), statusBadge(state.status, state.last_apply) ]))
	];
	var laBadge = applyBadge(state.last_apply);
	if (laBadge)
		statusRows.push(row(_('Last apply'), E('span', {}, [ document.createTextNode(fmtAgo(state.last_apply.ts) + '  '), laBadge ])));
	statusRows.push(row(_('Pending'), state.pending ? E('span', { 'style': 'color:#cc7a00;font-weight:bold;' }, _('changes staged — not yet applied')) : E('span', { 'style': 'color:#46a546;' }, _('config up to date'))));
	statusRows.push(row(_('Fetch path'), pathBadge(state.fetch_path)));
	statusRows.push(row(_('Self-update path'), pathBadge(state.update_path)));
	statusRows.push(row(_('Auto-apply'), state.auto_apply ? E('span', { 'style': 'color:#cc7a00;' }, _('ON')) : E('span', { 'style': 'color:#888;' }, _('off'))));
	if (state.last_apply && state.last_apply.fallback)
		statusRows.push(row(_('Hot-swap'), E('span', { 'style': 'color:#cc3300;' }, _('live apply failed and was rolled back — xray runs the previous config'))));
	var statusTable = E('table', { 'class': 'table' }, statusRows);

	var diffBox = state.pending ? E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'width': '28%' }, _('Added')),   E('td', { 'class': 'td' }, tagList(state.diff.added, '#46a546')) ]),
		E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td' }, _('Changed')), E('td', { 'class': 'td' }, tagList(state.diff.changed, '#cc7a00')) ]),
		E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td' }, _('Removed')), E('td', { 'class': 'td' }, tagList(state.diff.removed, '#cc3300')) ])
	]) : null;

	var srows = [ E('tr', { 'class': 'tr table-titles' }, [ E('th', { 'class': 'th' }, _('Tag')), E('th', { 'class': 'th' }, _('Address')), E('th', { 'class': 'th' }, _('Network')), E('th', { 'class': 'th' }, _('Mode')), E('th', { 'class': 'th' }, _('SNI')) ]) ];
	if (!state.servers.length) srows.push(E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'colspan': 5 }, E('em', {}, _('No servers installed yet — add a subscription, Fetch, then Apply.'))) ]));
	state.servers.forEach(function(s) {
		srows.push(E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td' }, E('strong', {}, s.tag)), E('td', { 'class': 'td' }, s.address + ':' + s.port), E('td', { 'class': 'td' }, s.network || '—'), E('td', { 'class': 'td' }, s.mode || '—'), E('td', { 'class': 'td' }, s.sni || '—') ]));
	});

	var content = [
		E('h3', {}, _('Subscriptions')),
		E('p', { 'style': 'color:#888;font-size:90%;margin:.2em 0 .6em;' }, _('Each subscription\'s servers become outbounds tagged "<prefix>-<location>" and are written as their own block in config.json. Use a unique prefix per subscription (keep "proxy" for your existing one to preserve routing).')),
		buildSubsTable(),
		(buildUsage() || E('div', {})),
		E('h3', {}, _('Schedule & auto-apply')),
		buildSettings(),
		E('h3', {}, _('Status')),
		statusTable,
		E('div', { 'style': 'margin:.6em 0;display:flex;gap:8px;' }, [ fetchBtn, applyBtn ]),
		(diffBox ? E('div', {}, [ E('h3', {}, _('Pending changes')), diffBox ]) : E('div', {})),
		E('h3', {}, _('Installed servers')),
		E('table', { 'class': 'table' }, srows)
	];
	while (root.firstChild) root.removeChild(root.firstChild);
	content.forEach(function(n) { root.appendChild(n); });
}

return view.extend({
	load: function() {
		return Promise.all([ refresh().catch(function() {}), checkUIVersion() ]);
	},
	render: function() {
		root = E('div', { 'class': 'cbi-section' });
		redraw();
		poll.add(refresh, 15);
		var nodes = [ E('h2', {}, _('Xray Subscriptions')), root ];
		if (staleUI) nodes.unshift(staleUI);
		return E('div', {}, nodes);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
