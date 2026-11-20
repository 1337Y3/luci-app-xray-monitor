'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require xray-diff as XrayDiff';

var callGet     = rpc.declare({ object: 'xray-monitor', method: 'mieru_get' });
var callCheck   = rpc.declare({ object: 'xray-monitor', method: 'mieru_check' });
var callAdd     = rpc.declare({ object: 'xray-monitor', method: 'mieru_add',  params: [ 'conn' ] });
var callEdit    = rpc.declare({ object: 'xray-monitor', method: 'mieru_edit', params: [ 'id', 'conn' ] });
var callDel     = rpc.declare({ object: 'xray-monitor', method: 'mieru_del',  params: [ 'id' ] });
var callRestart = rpc.declare({ object: 'xray-monitor', method: 'mieru_restart' });
var callTest    = rpc.declare({ object: 'xray-monitor', method: 'mieru_test', params: [ 'id' ] });
var callInstall = rpc.declare({ object: 'xray-monitor', method: 'mieru_install', params: [ 'version' ] });
var callStatus  = rpc.declare({ object: 'xray-monitor', method: 'status' });

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

var MULTIPLEX = [ 'MULTIPLEXING_LOW', 'MULTIPLEXING_MIDDLE', 'MULTIPLEXING_HIGH', 'MULTIPLEXING_OFF' ];
var HANDSHAKE = [ 'HANDSHAKE_STANDARD', 'HANDSHAKE_NO_WAIT' ];
var LOGLEVELS = [ 'ERROR', 'WARNING', 'INFO', 'DEBUG' ];
var PORT_TOK = /^[0-9]+(-[0-9]+)?\/(tcp|udp)$/i;

var root = null;
var state = { binary: { installed: 0, version: '', arch: '', installing: 0 },
              instances: [], tests: {}, install_result: null };
var latest = { installed: '', latest: '', update_available: 0, checked: 0 };
var prevInstalling = 0;
var installPending = false;
var installEpoch = 0, installRequestPending = false;
var refreshSequence = 0, refreshedSequence = 0;

function fmtAgo(e) {
	e = Number(e) || 0; if (!e) return _('never');
	var s = Math.max(0, Math.floor(Date.now() / 1000) - e);
	if (s < 60) return s + 's ' + _('ago');
	if (s < 3600) return Math.floor(s / 60) + 'm ' + _('ago');
	if (s < 86400) return Math.floor(s / 3600) + 'h ' + _('ago');
	return Math.floor(s / 86400) + 'd ' + _('ago');
}
function busy(btn, p) { btn.disabled = true; return p.then(function(v) { btn.disabled = false; return v; }, function(e) { btn.disabled = false; throw e; }); }
function refresh() {
	var epoch = installEpoch, sequence = ++refreshSequence;
	return callGet().then(function(r) {
		if (epoch !== installEpoch || installRequestPending || sequence < refreshedSequence) return;
		refreshedSequence = sequence;
		if (r && typeof r == 'object') state = r;
		// the detached install finished: surface its terminal outcome once
		var nowInstalling = (state.binary && Number(state.binary.installing)) ? 1 : 0;
		if ((prevInstalling || installPending) && !nowInstalling && state.install_result && Number(state.install_result.ts)) {
			installPending = false;
			ui.addNotification(null, E('p', [
				E('strong', {}, state.install_result.ok ? _('mieru install: ') : _('mieru install failed: ')),
				document.createTextNode(state.install_result.msg || _('no details'))
			]), state.install_result.ok ? 'info' : 'error');
		}
		prevInstalling = nowInstalling;
		redraw();
	});
}
function row(k, v) { return E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left', 'width': '28%' }, E('strong', {}, k)), E('td', { 'class': 'td left' }, v) ]); }
function notify(res, okMsg) {
	if (res && res.ok) ui.addNotification(null, E('p', okMsg), 'info');
	else ui.addNotification(null, E('p', [ E('strong', {}, _('Failed: ')), document.createTextNode((res && res.msg) || _('error')) ]), 'error');
	return refresh();
}
function rpcFail(e) {
	ui.addNotification(null, E('p', [ E('strong', {}, _('Failed: ')),
		document.createTextNode((e && (e.message || e.msg)) || _('error')) ]), 'error');
	return refresh();
}

function stateBadge(inst) {
	if (!inst.enabled) return E('span', { 'style': 'background:#888;color:#fff;padding:2px 8px;border-radius:3px;' }, _('disabled'));
	if (inst.running) return E('span', { 'style': 'background:#46a546;color:#fff;padding:2px 8px;border-radius:3px;' }, _('running'));
	return E('span', { 'style': 'background:#cc7a00;color:#fff;padding:2px 8px;border-radius:3px;' }, _('stopped'));
}
function testBadge(t) {
	if (!t || !Number(t.ts)) return E('span', { 'style': 'color:#888' }, '—');
	var ok = (t.ok === true || Number(t.ok) === 1);
	var el = E('span', { 'style': 'color:' + (ok ? '#46a546' : '#cc3300') + ';' },
		(ok ? _('ok') : _('fail')) + ' · ' + fmtAgo(t.ts));
	if (t.detail) el.title = t.detail;
	return el;
}

// --- connection add/edit modal ----------------------------------------------
// One modal, two modes: conn === null adds, else edits that row. Credentials
// are never echoed back by the backend, so on edit they stay blank = keep.
function connModal(conn) {
	var editing = !!conn;
	var f = {};
	function inp(key, type, val, ph, width) {
		f[key] = E('input', { 'type': type || 'text', 'class': 'cbi-input-text',
			'style': 'width:' + (width || '220px') + ';', 'value': val || '', 'placeholder': ph || '' });
		return f[key];
	}
	function sel(key, opts, val) {
		var es = opts.map(function(o) {
			var opt = E('option', { 'value': o }, o);
			if (o == val) opt.selected = true;
			return opt;
		});
		f[key] = E('select', { 'class': 'cbi-input-select' }, es);
		return f[key];
	}
	var portsV = conn ? (conn.ports || '') : '';
	var lanChk = E('input', { 'type': 'checkbox', 'checked': (conn && Number(conn.lan)) ? '' : null });
	f.lan = lanChk;
	var table = E('table', { 'class': 'table' }, [
		row(_('Label'), inp('label', 'text', conn ? conn.label : '', 'work', '160px')),
		row(_('Server IP'), inp('server_ip', 'text', conn ? (conn.server_ip || '') : '', '12.34.56.78')),
		row(_('Server domain (optional)'), inp('server_domain', 'text', conn ? (conn.server_domain || '') : '', 'example.com')),
		row(_('Server ports'), inp('ports', 'text', portsV, '2027/tcp 2012-2022/udp', '100%')),
		row(_('Username'), inp('username', 'text', '', editing ? _('(blank = keep)') : '')),
		row(_('Password'), inp('password', 'password', '', editing ? _('(blank = keep)') : '')),
		row(_('MTU'), inp('mtu', 'text', conn ? String(conn.mtu || 1400) : '1400', '1400 (1280-1400)', '100px')),
		row(_('Multiplexing'), sel('multiplexing', MULTIPLEX, conn ? conn.mux : 'MULTIPLEXING_LOW')),
		row(_('Handshake'), sel('handshake', HANDSHAKE, conn ? conn.hs : 'HANDSHAKE_STANDARD')),
		row(_('SOCKS5 listen port'), inp('socks5_port', 'text', conn ? String(conn.socks5_port || '') : '', '1080', '100px')),
		row(_('SOCKS5 on LAN'), E('label', { 'style': 'display:inline-flex;gap:6px;align-items:center;' }, [ lanChk,
			E('span', {}, _('accept connections from the LAN (default: loopback only)')) ])),
		row(_('Transparent port (optional)'), inp('tproxy_port', 'text', conn ? (String(conn.tproxy_port || 0) === '0' ? '' : String(conn.tproxy_port)) : '', '12345 (blank = off)', '100px')),
		row(_('Logging'), sel('logging', LOGLEVELS, conn ? conn.log : 'ERROR'))
	]);
	function collect() {
		var ports = (f.ports.value || '').trim().split(/\s+/).filter(Boolean);
		var sock = (f.socks5_port.value || '').trim();
		var tp = (f.tproxy_port.value || '').trim();
		var mtu = (f.mtu.value || '').trim();
		if (!/^[A-Za-z0-9_.-]{1,32}$/.test((f.label.value || '').trim()))
			return { err: _('Label: 1-32 chars of letters, digits, . _ -') };
		if (!(f.server_ip.value || '').trim() && !(f.server_domain.value || '').trim())
			return { err: _('A server IP or domain is required') };
		if (!ports.length || !ports.every(function(p) { return PORT_TOK.test(p); }))
			return { err: _('Ports: space-separated <port>[-<port>]/tcp|udp, e.g. 2027/tcp 2012-2022/udp') };
		if (!/^[0-9]+$/.test(sock) || Number(sock) < 1 || Number(sock) > 65535)
			return { err: _('SOCKS5 port must be 1-65535') };
		if (tp && (!/^[0-9]+$/.test(tp) || Number(tp) < 1 || Number(tp) > 65535))
			return { err: _('Transparent port must be 1-65535 (or blank)') };
		if (tp && tp == sock)
			return { err: _('Transparent port must differ from the SOCKS5 port') };
		if (mtu && (!/^[0-9]+$/.test(mtu) || Number(mtu) < 1280 || Number(mtu) > 1400))
			return { err: _('MTU must be 1280-1400') };
		if (!editing && (!(f.username.value || '').trim() || !(f.password.value || '').trim()))
			return { err: _('Username and password are required') };
		return { conn: {
			label: (f.label.value || '').trim(),
			server_ip: (f.server_ip.value || '').trim(),
			server_domain: (f.server_domain.value || '').trim(),
			server_ports: ports,
			username: (f.username.value || '').trim(),
			password: f.password.value || '',
			mtu: mtu ? Number(mtu) : 1400,
			multiplexing: f.multiplexing.value,
			handshake: f.handshake.value,
			socks5_port: Number(sock),
			tproxy_port: tp ? Number(tp) : 0,
			lan: lanChk.checked ? 1 : 0,
			logging: f.logging.value
		} };
	}
	var saveBtn = E('button', { 'class': 'cbi-button cbi-button-positive important' }, editing ? _('Save') : _('Add'));
	saveBtn.addEventListener('click', function() {
		var r = collect();
		if (r.err) return ui.addNotification(null, E('p', r.err), 'warning');
		busy(saveBtn, (editing ? callEdit(conn.id, r.conn) : callAdd(r.conn)).then(function(res) {
			ui.hideModal();
			return notify(res, editing ? _('Connection saved. Restart the service to apply.') : _('Connection added. Restart the service to apply.'));
		}));
	});
	var cancelBtn = E('button', { 'class': 'btn' }, _('Cancel'));
	cancelBtn.addEventListener('click', ui.hideModal);
	ui.showModal((editing ? _('Edit mieru connection') : _('Add mieru connection')), [
		E('p', { 'style': 'color:#888;font-size:90%;' },
			_('Each connection runs its own mieru client with its own SOCKS5 port. The transparent port uses separately installed redsocks, which binds all interfaces. Apply the README LAN-only INPUT rules before enabling it, then direct REDIRECTed TCP (ruantiblock or your own rules) to this port.')),
		table,
		E('div', { 'class': 'right', 'style': 'margin-top:1em;' }, [ cancelBtn, ' ', saveBtn ])
	]);
}

function buildBinaryCard() {
	var b = state.binary || {};
	var verCell;
	if (b.installing)
		verCell = E('span', { 'style': 'color:#cc7a00;' }, _('downloading…'));
	else if (b.installed)
		verCell = E('span', {}, [ E('strong', {}, b.version || '?'),
			E('span', { 'style': 'color:#888;' }, '  (' + (b.arch || '?') + ')') ]);
	else
		verCell = E('span', { 'style': 'color:#cc3300;' }, _('not installed'));
	var rows = [ row(_('Binary'), verCell) ];
	if (latest.checked)
		rows.push(row(_('Latest release'), latest.latest
			? E('span', {}, [ latest.latest ].concat(latest.update_available
				? [ E('span', { 'style': 'color:#cc7a00;' }, '  — ' + _('update available')) ] : []))
			: E('span', { 'style': 'color:#888;' }, _('unreachable'))));
	var installBtn = E('button', { 'class': 'cbi-button cbi-button-action' },
		b.installed ? _('Update binary') : _('Install binary'));
	installBtn.addEventListener('click', function() {
		var request = ++installEpoch;
		installRequestPending = true;
		busy(installBtn, callInstall('').then(function(res) {
			if (request !== installEpoch) return;
			installRequestPending = false;
			++installEpoch;
			installPending = !!(res && res.ok);
			return notify(res, res && res.running ? _('An install is already running')
				: _('Download started - the version card updates when it finishes.'));
		}, function(e) {
			if (request !== installEpoch) return;
			installRequestPending = false;
			++installEpoch;
			return rpcFail(e);
		}));
	});
	var checkBtn = E('button', { 'class': 'cbi-button cbi-button-neutral' }, _('Check for updates'));
	checkBtn.addEventListener('click', function() {
		busy(checkBtn, callCheck().then(function(r) {
			if (r && typeof r == 'object') {
				latest = { installed: r.installed || '', latest: r.latest || '',
					update_available: (r.update_available === true || Number(r.update_available) === 1) ? 1 : 0,
					checked: Math.floor(Date.now() / 1000) };
				redraw();
			}
		}, rpcFail));
	});
	rows.push(row('', E('div', { 'style': 'display:flex;gap:8px;' }, [ installBtn, checkBtn ])));
	if (!b.installed && (state.instances || []).length)
		rows.push(row('', E('span', { 'style': 'color:#cc7a00;' },
			_('connections exist but the binary is missing - install it, then Restart'))));
	return E('div', {}, [ E('h3', {}, _('mieru binary')), E('table', { 'class': 'table' }, rows) ]);
}

function buildConnTable() {
	var head = E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('Label')), E('th', { 'class': 'th' }, _('Server')),
		E('th', { 'class': 'th' }, _('Ports')), E('th', { 'class': 'th' }, _('SOCKS5')),
		E('th', { 'class': 'th' }, _('Transparent')), E('th', { 'class': 'th' }, _('State')),
		E('th', { 'class': 'th' }, _('Last test')), E('th', { 'class': 'th', 'style': 'width:1%' }, '')
	]);
	var rows = [ head ];
	if (!(state.instances || []).length)
		rows.push(E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'colspan': 8 },
			E('em', {}, _('No mieru connections yet - add one.'))) ]));
	(state.instances || []).forEach(function(c) {
		var test = (state.tests || {})[c.id];
		var edit = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Edit'));
		var testb = E('button', { 'class': 'cbi-button cbi-button-neutral' }, _('Test'));
		var del = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('Delete'));
		edit.addEventListener('click', function() { connModal(c); });
		testb.addEventListener('click', function() {
			busy(testb, callTest(c.id).then(function(res) { return notify(res, _('Test passed.')); }, rpcFail));
		});
		del.addEventListener('click', function() {
			if (!confirm(_('Delete mieru connection "') + c.label + _('"? Restart the service afterwards.'))) return;
			busy(del, callDel(c.id).then(function(res) { return notify(res, _('Connection deleted.')); }));
		});
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, E('strong', {}, c.label)),
			E('td', { 'class': 'td' }, c.server || '—'),
			E('td', { 'class': 'td', 'style': 'font-family:monospace;' }, c.ports || '—'),
			E('td', { 'class': 'td' }, String(c.socks5_port || '—')),
			E('td', { 'class': 'td' }, c.tproxy_port ? String(c.tproxy_port) : E('span', { 'style': 'color:#888' }, '—')),
			E('td', { 'class': 'td' }, stateBadge(c)),
			E('td', { 'class': 'td' }, testBadge(test)),
			E('td', { 'class': 'td', 'style': 'white-space:nowrap' }, [ edit, ' ', testb, ' ', del ])
		]));
	});
	var addBtn = E('button', { 'class': 'cbi-button cbi-button-add' }, _('Add connection'));
	addBtn.addEventListener('click', function() { connModal(null); });
	rows.push(E('tr', { 'class': 'tr', 'style': 'border-top:2px solid rgba(128,128,128,.3)' }, [
		E('td', { 'class': 'td', 'colspan': 7 }, ''), E('td', { 'class': 'td' }, addBtn)
	]));
	return E('table', { 'class': 'table' }, rows);
}

function redraw() {
	if (!root) return;
	var restartBtn = E('button', { 'class': 'cbi-button cbi-button-apply' }, _('Restart service'));
	restartBtn.addEventListener('click', function() {
		busy(restartBtn, callRestart().then(function(res) { return notify(res, _('Service restarted.')); }, rpcFail));
	});
	var content = [
		E('h3', {}, _('Connections')),
		E('p', { 'style': 'color:#888;font-size:90%;margin:.2em 0 .6em;' },
			_('Independent mieru proxy clients. SOCKS5 clients point at <router-ip>:<SOCKS5 port>; redirected TCP (ruantiblock, REDIRECT rules) goes to the transparent port.')),
		buildConnTable(),
		E('div', { 'style': 'margin:.6em 0;display:flex;gap:8px;' }, [ restartBtn ]),
		buildBinaryCard()
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
		var nodes = [ E('h2', {}, _('Mieru')), root ];
		if (staleUI) nodes.unshift(staleUI);
		return E('div', {}, nodes);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
