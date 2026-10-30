'use strict';
'require view';
'require rpc';
'require ui';
'require xray-diff as XrayDiff';

var callList    = rpc.declare({ object: 'xray-monitor', method: 'backups_list' });
var callGetBak  = rpc.declare({ object: 'xray-monitor', method: 'backups_get',    params: [ 'name' ] });
var callDelete  = rpc.declare({ object: 'xray-monitor', method: 'backups_delete', params: [ 'name' ] });
var callPin     = rpc.declare({ object: 'xray-monitor', method: 'backups_pin',    params: [ 'name', 'pinned' ] });
var callRestore = rpc.declare({ object: 'xray-monitor', method: 'backups_restore', params: [ 'name' ] });
var callDiff    = rpc.declare({ object: 'xray-monitor', method: 'config_diff', params: [ 'name' ] });
var callGetCfg  = rpc.declare({ object: 'xray-monitor', method: 'config_get' });

var KIND_LABEL = { auto: _('Auto'), manual: _('Manual'), preapi: _('Pre-API') };

var listData = [];   // last backups_list result, for redraws
var buttons  = [];   // every action button currently on screen, for setBusy

function setBusy(on) { buttons.forEach(function(b) { b.disabled = on; }); }

function fmtBytes(n) {
	if (typeof n != 'number' || isNaN(n) || n < 0) return '-';
	if (n < 1024) return n + ' B';
	var units = [ 'kB', 'MB', 'GB' ], i = -1;
	do { n /= 1024; i++; } while (n >= 1024 && i < units.length - 1);
	return (n >= 100 ? Math.round(n) : Math.round(n * 10) / 10) + ' ' + units[i];
}

/* '20260102-030405' -> '2026-01-02 03:04:05' (string math: no timezone games) */
function fmtDate(ts) {
	if (typeof ts != 'string' || !/^\d{8}-\d{6}$/.test(ts)) return ts || '-';
	return ts.substring(0, 4) + '-' + ts.substring(4, 6) + '-' + ts.substring(6, 8) + ' ' +
	       ts.substring(9, 11) + ':' + ts.substring(11, 13) + ':' + ts.substring(13, 15);
}

function notify(res, okText, failText) {
	if (res && res.ok)
		ui.addNotification(null, E('p', {}, okText + ' ' + (res.msg || '')), 'info');
	else
		ui.addNotification(null, E('p', {}, [
			E('strong', {}, failText),
			document.createTextNode(' ' + ((res && res.msg) || _('unknown error')))
		]), 'error');
}

function btn(label, cls, fn) {
	var b = E('button', { 'class': 'cbi-button ' + cls, 'style': 'margin:1px 2px;' }, label);
	b.addEventListener('click', fn);
	buttons.push(b);
	return b;
}

/* modal with a Close button; ui.showModal replaces the previous modal */
function showModal(title, nodes) {
	var close = E('button', { 'class': 'btn cbi-button' }, _('Close'));
	close.addEventListener('click', ui.hideModal);
	ui.showModal(title, nodes.concat([ E('div', { 'class': 'right' }, [ close ]) ]));
}

function download(name, text) {
	var url = URL.createObjectURL(new Blob([ text ], { type: 'application/json' }));
	var a = E('a', { 'href': url, 'download': name });
	document.body.appendChild(a);
	a.click();
	document.body.removeChild(a);
	URL.revokeObjectURL(url);
}

function viewBackup(b) {
	setBusy(true);
	callGetBak(b.name).then(function(res) {
		setBusy(false);
		if (!res || !res.ok) { notify(res, '', _('Cannot show backup:')); return; }
		showModal(_('Backup %s').format(b.name), [
			E('p', {}, [
				E('strong', {}, KIND_LABEL[b.kind] || b.kind), ' · ',
				fmtDate(b.ts), ' · ', fmtBytes(b.size), ' · ',
				b.pinned ? _('pinned') : _('not pinned')
			]),
			E('pre', {
				'style': 'max-height:60vh;overflow:auto;margin:0;white-space:pre;font-family:monospace;font-size:12px;'
			}, (res.config || '') + '\n')
		]);
	}, function() { setBusy(false); ui.addNotification(null, E('p', {}, _('View call failed.')), 'error'); });
}

function diffBackup(b) {
	setBusy(true);
	Promise.all([ callGetCfg(), callGetBak(b.name), callDiff(b.name) ]).then(function(r) {
		setBusy(false);
		var cur = (r[0] && r[0].config) || '',
		    bak = (r[1] && r[1].config) || '',
		    sem = r[2] || {};
		if (sem.error) {
			ui.addNotification(null, E('p', {}, _('Diff failed: ') + sem.error), 'error');
			return;
		}
		var nodes = [];
		if ((!sem.added || !sem.added.length) && (!sem.removed || !sem.removed.length) && (!sem.changed || !sem.changed.length))
			nodes.push(E('p', {}, E('em', {}, _('This backup is identical to the current config.'))));
		else {
			nodes.push(E('p', {}, _('Compared to the current config, restoring this backup would:')));
			nodes.push(XrayDiff.renderSemantic(sem));
		}
		nodes.push(E('p', { 'style': 'margin-top:1em;' }, [
			E('strong', {}, _('Text diff (current → backup)')), ' — ',
			_("lines marked '-' exist only in the current config, lines marked '+' only in the backup."
		)]));
		nodes.push(XrayDiff.renderUnified(cur, bak));
		showModal(_('Diff with current: %s').format(b.name), nodes);
	}, function() { setBusy(false); ui.addNotification(null, E('p', {}, _('Diff call failed.')), 'error'); });
}

function restoreBackup(b) {
	if (!confirm(_('Restore backup %s?\n\nThe current config is backed up first (config.json.bak.manual.*), then this backup is validated with xray -test, installed and xray is restarted. If xray fails to come back up, everything is rolled back automatically.').format(b.name)))
		return;
	setBusy(true);
	callRestore(b.name).then(function(res) {
		setBusy(false);
		notify(res, _('Restored and restarted xray.'), _('Restore failed (not applied):'));
		refresh();
	}, function() { setBusy(false); ui.addNotification(null, E('p', {}, _('Restore call failed.')), 'error'); });
}

function pinBackup(b) {
	setBusy(true);
	callPin(b.name, b.pinned ? 0 : 1).then(function(res) {
		setBusy(false);
		notify(res, b.pinned ? _('Unpinned.') : _('Pinned.'), _('Pin failed:'));
		refresh();
	}, function() { setBusy(false); ui.addNotification(null, E('p', {}, _('Pin call failed.')), 'error'); });
}

function deleteBackup(b) {
	if (!confirm(_('Delete backup %s? This cannot be undone.').format(b.name)))
		return;
	setBusy(true);
	callDelete(b.name).then(function(res) {
		setBusy(false);
		notify(res, _('Deleted.'), _('Delete failed:'));
		refresh();
	}, function() { setBusy(false); ui.addNotification(null, E('p', {}, _('Delete call failed.')), 'error'); });
}

function downloadBackup(b) {
	setBusy(true);
	callGetBak(b.name).then(function(res) {
		setBusy(false);
		if (!res || !res.ok) { notify(res, '', _('Cannot download backup:')); return; }
		download(b.name, res.config || '');
	}, function() { setBusy(false); ui.addNotification(null, E('p', {}, _('Download call failed.')), 'error'); });
}

function actionsCell(b) {
	var cell = E('td', { 'class': 'td', 'style': 'white-space:nowrap;' });
	cell.appendChild(btn(_('View'), 'cbi-button-neutral', function() { viewBackup(b); }));
	cell.appendChild(btn(_('Diff'), 'cbi-button-neutral', function() { diffBackup(b); }));
	cell.appendChild(btn(_('Download'), 'cbi-button-neutral', function() { downloadBackup(b); }));
	cell.appendChild(btn(b.pinned ? _('Unpin') : _('Pin'), 'cbi-button-neutral', function() { pinBackup(b); }));
	cell.appendChild(btn(_('Restore'), 'cbi-button-action', function() { restoreBackup(b); }));
	cell.appendChild(btn(_('Delete'), 'cbi-button-negative', function() { deleteBackup(b); }));
	return cell;
}

var tableBox = null;   // replaced in place on every redraw

function redraw(list) {
	buttons = [];
	var rows = [ E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('Backup file')),
		E('th', { 'class': 'th' }, _('Type')),
		E('th', { 'class': 'th' }, _('Date')),
		E('th', { 'class': 'th right' }, _('Size')),
		E('th', { 'class': 'th center' }, _('Pinned')),
		E('th', { 'class': 'th' }, _('Actions'))
	]) ];
	var i, b;
	if (!list || !list.length)
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': 6 }, E('em', {}, _('No backups yet. A backup is created automatically before every config write (Save & apply in the Config tab, subscription update, restore).')))
		]));
	else
		for (i = 0; i < list.length; i++) {
			b = list[i];
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, E('code', { 'style': 'font-size:90%;word-break:break-all;' }, b.name)),
				E('td', { 'class': 'td' }, KIND_LABEL[b.kind] || b.kind),
				E('td', { 'class': 'td', 'style': 'white-space:nowrap;' }, fmtDate(b.ts)),
				E('td', { 'class': 'td right' }, fmtBytes(b.size)),
				E('td', { 'class': 'td center' }, b.pinned ? E('strong', { 'style': 'color:#46a546;' }, '✓') : '—'),
				actionsCell(b)
			]));
		}

	var refreshBtn = E('button', { 'class': 'cbi-button cbi-button-neutral' }, _('Refresh'));
	refreshBtn.addEventListener('click', function(ev) { ev.target.disabled = true; refresh(); });

	var fresh = E('div', {}, [
		E('div', { 'style': 'margin:.5em 0;display:flex;justify-content:flex-end;' }, [ refreshBtn ]),
		E('table', { 'class': 'table' }, rows)
	]);

	if (tableBox)
		tableBox.parentNode.replaceChild(fresh, tableBox);
	tableBox = fresh;
}

function refresh() {
	callList().then(function(res) {
		listData = (res && res.backups) ? res.backups : [];
		redraw(listData);
	}, function() {
		ui.addNotification(null, E('p', {}, _('Failed to list backups.')), 'error');
	});
}

return view.extend({
	load: function() { return callList().catch(function() { return {}; }); },

	render: function(data) {
		listData = (data && data.backups) ? data.backups : [];
		redraw(listData);
		return E('div', {}, [
			E('h2', {}, _('Backups')),
			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, [
					_('Every config write (Save & apply, subscription update, restore) stores the previous config as '),
					E('code', {}, 'config.json.bak.<type>.<timestamp>'),
					_(' in /etc/xray. Older backups are pruned automatically: only the newest '),
					E('strong', {}, 'backup_keep'),
					_(' unpinned ones are kept (see the "backup_keep" option in /etc/config/xray-monitor; 0 keeps everything). ')
				]),
				E('p', {}, [
					E('strong', {}, _('Pinned')), _(' backups are never pruned and never renamed away — pin a backup you care about (e.g. before restoring an old one, since a restore itself creates a new backup that can push old ones out of the budget). '),
					E('strong', {}, _('Restore')), _(' validates the backup with xray -test, backs up the current config, then installs and restarts; it rolls back automatically if xray does not come back up.')
				]),
				tableBox
			])
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
