'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var callStatus    = rpc.declare({ object: 'xray-monitor', method: 'status' });
var callStats     = rpc.declare({ object: 'xray-monitor', method: 'stats' });
var callOutbounds = rpc.declare({ object: 'xray-monitor', method: 'outbounds' });
var callOutMeta   = rpc.declare({ object: 'xray-monitor', method: 'out_meta' });
var callProbeSet  = rpc.declare({ object: 'xray-monitor', method: 'probe_set', params: [ 'tag', 'disabled' ] });
var callReset     = rpc.declare({ object: 'xray-monitor', method: 'reset' });
var callEnableApi = rpc.declare({ object: 'xray-monitor', method: 'enable_api' });
var callValidate  = rpc.declare({ object: 'xray-monitor', method: 'validate' });
var callUpdChk    = rpc.declare({ object: 'xray-monitor', method: 'update_check' });
var callUpdApply  = rpc.declare({ object: 'xray-monitor', method: 'update_apply' });
var callE2eStatus = rpc.declare({ object: 'xray-monitor', method: 'e2e_status' });
var callE2eStart  = rpc.declare({ object: 'xray-monitor', method: 'e2e_start' });

var prev = null;  /* { ts, flat } for rate calculation */
var root = null;  /* container element to redraw into */
var e2eBtnEl = null;  /* "Run E2E check" button (kept across redraws) */
var state = {
	status: {},
	parsed: { data: { inbound: {}, outbound: {} }, flat: {} },
	rates: {},      /* "kind/name/dir" -> bytes/s */
	health: {},     /* tag -> { up, ms, active } */
	e2e: { running: false, ts: 0, results: {} },  /* last end-to-end check */
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
	if (h.disabled)      { color = '#888';    label = 'ping off'; }
	else if (h.up === 1) { color = '#46a546'; label = 'connected' + (h.ms > 0 ? ' · ' + h.ms + ' ms' : ''); }
	else if (h.up === 0) { color = '#cc3300'; label = 'down'; }
	else                 { color = '#888';    label = 'unknown'; }
	var els = [
		E('span', { 'style': 'color:' + color + ';font-weight:bold;' }, h.disabled ? '○ ' : '● '),
		E('span', {}, label)
	];
	if (h.active)
		els.push(E('span', { 'style': 'margin-left:6px;color:#46a546;font-size:85%;' }, '(live)'));
	return E('span', {}, els);
}

/* Last end-to-end verdict per exit: did real traffic FLOW through it? A TCP
   ping can say "reachable" while DPI freezes the stream after the first few
   KB — that shows up here as "stalled" (bytes arrived, body never finished). */
function e2eCell(tag) {
	var r = (state.e2e && state.e2e.results) ? state.e2e.results[tag] : null;
	var running = !!(state.e2e && state.e2e.running);
	if (!r) return E('span', { 'style': 'color:#888' }, running ? '…' : '–');
	var map = {
		ok:      { color: '#46a546', label: _('ok') },
		stalled: { color: '#dd8500', label: _('stalled') },
		fail:    { color: '#cc3300', label: _('fail') },
		skipped: { color: '#888',    label: _('skipped') }
	};
	var m = map[r.status] || { color: '#888', label: r.status || '–' };
	var title = _('E2E check: TTFB ') + (r.ttfb_ms || 0) + ' ms · ' +
	            (r.bytes || 0) + ' B · ' + fmtBytes(r.speed_bps || 0) + '/s' +
	            (state.e2e.ts ? ' · ' + new Date(state.e2e.ts * 1000).toLocaleString() : '');
	var els = [
		E('span', { 'style': 'color:' + m.color + ';font-weight:bold;' }, '● '),
		E('span', {}, m.label)
	];
	var det = '';
	if (r.status === 'ok')            det = fmtBytes(r.speed_bps || 0) + '/s';
	else if (r.status === 'stalled')  det = _('froze at ') + fmtBytes(r.bytes || 0);
	if (det)
		els.push(E('span', { 'style': 'margin-left:6px;font-size:85%;color:#666;' }, det));
	return E('span', { 'title': title }, els);
}

/* Per-outbound toggle for the active TCP probe. Off = the endpoint is never
   dialled (use for a "blown" exit whose handshake draws an ISP reset). */
function pingToggle(tag) {
	var h = state.health[tag];
	if (!h) return E('span', { 'style': 'color:#888' }, '–');  /* no probeable endpoint (e.g. direct) */
	var enabled = !h.disabled;
	var cb = E('input', { 'type': 'checkbox' });
	cb.checked = enabled;
	cb.addEventListener('change', function() {
		var wantDisabled = cb.checked ? '0' : '1';
		cb.disabled = true;
		callProbeSet(tag, wantDisabled).then(function(res) {
			if (!res || !res.ok) throw new Error((res && res.msg) || 'failed');
			if (state.health[tag]) state.health[tag].disabled = (wantDisabled === '1');
			return refreshMeta();   /* confirm cheaply; never triggers a probe */
		}).then(function() {
			cb.disabled = false;
		}, function() {
			cb.disabled = false;
			cb.checked = enabled;  /* revert on failure */
			ui.addNotification(null, E('p', _('Could not change ping check for ') + tag + '.'), 'error');
		});
	});
	return E('label', { 'style': 'display:flex;align-items:center;gap:6px;cursor:pointer;' }, [
		cb, E('span', { 'style': 'font-size:90%;color:#666;' }, enabled ? _('on') : _('off'))
	]);
}

function buildTable(title, kind, withStatus) {
	var group = state.parsed.data[kind] || {};
	var names = Object.keys(group);
	/* Outbounds: also list probed exits with no traffic counters yet, so every
	   configured exit (incl. a disabled-from-ping one) still gets a toggle. */
	if (kind === 'outbound')
		Object.keys(state.health).forEach(function(t) { if (names.indexOf(t) < 0) names.push(t); });
	names.sort();

	var head = [
		E('th', { 'class': 'th' }, _('Tag')),
		E('th', { 'class': 'th right' }, _('Upload')),
		E('th', { 'class': 'th right' }, _('Download')),
		E('th', { 'class': 'th right' }, '↑ ' + _('rate')),
		E('th', { 'class': 'th right' }, '↓ ' + _('rate'))
	];
	if (withStatus) {
		head.push(E('th', { 'class': 'th' }, _('Status')));
		head.push(E('th', { 'class': 'th' }, _('E2E')));
		head.push(E('th', { 'class': 'th' }, _('Ping check')));
	}
	var rows = [ E('tr', { 'class': 'tr table-titles' }, head) ];

	if (!names.length)
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': withStatus ? 8 : 5 }, E('em', {}, _('No data')))
		]));

	names.forEach(function(name) {
		var g = group[name] || { up: 0, down: 0 };
		var cells = [
			E('td', { 'class': 'td' }, E('strong', {}, name)),
			E('td', { 'class': 'td right' }, fmtBytes(g.up)),
			E('td', { 'class': 'td right' }, fmtBytes(g.down)),
			E('td', { 'class': 'td right' }, fmtRate(kind, name, 'uplink')),
			E('td', { 'class': 'td right' }, fmtRate(kind, name, 'downlink'))
		];
		if (withStatus) {
			cells.push(E('td', { 'class': 'td' }, statusCell(name)));
			cells.push(E('td', { 'class': 'td' }, e2eCell(name)));
			cells.push(E('td', { 'class': 'td' }, pingToggle(name)));
		}
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
			row(_('Xray version'), s.version || '–'),
			row(_('Add-on version'), s.app_version || '–')
		])
	]);
}

/* Banner for missing API services. Two triggers: any of Stats/Handler/Routing
   service absent from the config (status.api_missing, config-derived), or the
   stats endpoint not answering although the page expected counters. Either way
   `enable_api` (enable-api.uc) can fix it: it installs all three services. */
function apiBanner() {
	var s = state.status || {};
	if (!s.running) return null;
	var missing = (s.api_missing && s.api_missing.length) ? s.api_missing : [];
	if (!missing.length && state.apiOk !== false) return null;
	var btn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Enable API services'));
	btn.addEventListener('click', function() {
		btn.disabled = true;
		callEnableApi().then(function(res) {
			btn.disabled = false;
			if (res && res.ok) ui.addNotification(null, E('p', _('API services enabled: ') + (res.msg || '')), 'info');
			else ui.addNotification(null, E('p', _('Could not enable API services: ') + ((res && res.msg) || _('unknown error'))), 'error');
			return refreshStats();
		}, function() { btn.disabled = false; ui.addNotification(null, E('p', _('Enable call failed.')), 'error'); });
	});
	var msg = missing.length
		? _('Xray is running but its config is missing API services: ') + missing.join(', ') +
		  _(' — needed for traffic stats and live routing/outbound control.')
		: _('Xray is running but the Stats API was not detected on 127.0.0.1:10085 — monitoring needs it.');
	return E('div', {
		'style': 'margin:.5em 0;padding:10px;border-radius:6px;background:#fdf0d5;border:1px solid #e0b34a;color:#222;' +
		         'display:flex;align-items:center;gap:12px;flex-wrap:wrap;'
	}, [
		E('span', {}, msg),
		btn
	]);
}

var CONFDIR_DISMISS_KEY = 'luci-app-xray-monitor.confdir-dismissed';

function confdirBanner() {
	var s = state.status || {};
	if (!s.confdir_dup) return null;
	try { if (localStorage.getItem(CONFDIR_DISMISS_KEY)) return null; } catch (e) {}

	var dismiss = E('button', {
		'class': 'cbi-button',
		'style': 'margin-left:auto;align-self:flex-start;line-height:1;',
		'title': _('Dismiss this warning')
	}, '✕');
	dismiss.addEventListener('click', function() {
		try { localStorage.setItem(CONFDIR_DISMISS_KEY, '1'); } catch (e) {}
		redraw();
	});

	return E('div', {
		'style': 'margin:.5em 0;padding:10px;border-radius:6px;background:#fdecea;border:1px solid #d09999;color:#222;' +
		         'display:flex;gap:12px;align-items:flex-start;'
	}, [
		E('div', {}, [
			E('strong', {}, _('Config double-load detected. ')),
			E('span', {}, _('xray is started with both -confdir and -config pointing at the same file, so config.json is loaded twice. Usually harmless (xray merges by tag), but it can make inbounds — including the stats API on 10085 — intermittently fail to bind.')),
			E('p', { 'style': 'margin:.6em 0 .2em;' }, E('strong', {}, _('To fix it (make the config load once):'))),
			E('ol', { 'style': 'margin:.2em 0 0 1.2em;padding:0;line-height:1.5;' }, [
				E('li', {}, [ _('See how xray is launched: '),
					E('code', {}, 'uci show xray; grep -nE "confdir|config" /etc/init.d/xray') ]),
				E('li', {}, [ _('Remove one flag so '), E('code', {}, '/etc/xray/config.json'),
					_(' loads once — usually drop '), E('code', {}, '-confdir'), _(' and keep '),
					E('code', {}, '-config'), _('; on a real multi-file confdir setup, drop the redundant '),
					E('code', {}, '-config'), _(' instead.') ]),
				E('li', {}, [ _('Apply and verify: '),
					E('code', {}, 'uci commit xray && /etc/init.d/xray restart'),
					_(', then '), E('code', {}, 'xray api statsquery --server=127.0.0.1:10085'),
					_(' should dial.') ])
			])
		]),
		dismiss
	]);
}

function redraw() {
	if (!root) return;
	var content = [
		confdirBanner(),
		apiBanner(),
		buildStatusCard(),
		buildTable(_('Outbounds (VPS exits)'), 'outbound', true),
		buildTable(_('Inbounds (tproxy)'), 'inbound', false),
		E('div', { 'style': 'margin-top:1em;color:#888;font-size:90%;' },
			_('Traffic auto-refreshes every 5s; connectivity every 30s while “Auto-refresh ping” is on. ' +
			  'Counters are cumulative since the last xray restart. ' +
			  'Turn off an exit\'s Ping check to stop dialling it — useful for a blown server whose handshake draws an ISP reset. ' +
			  'The E2E column shows the last end-to-end check: ok = a real body was pulled through the exit, ' +
			  'stalled = data flowed but the body froze part-way (DPI throttling), fail = no usable connection. ' +
			  'Use “Run E2E check” to re-measure — it pulls ~1 MB per exit and takes tens of seconds.'))
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

/* Cheap, probe-free refresh: every exit's tag + disabled flag. Used on first
   paint (so toggles + 'ping off' show instantly) and after a toggle, so the
   Ping check control never has to wait on — or trigger — an active probe. */
function refreshMeta() {
	return callOutMeta().then(function(r) {
		((r && r.outbounds) || []).forEach(function(o) {
			var h = state.health[o.tag] || (state.health[o.tag] = { tag: o.tag });
			h.disabled = !!o.disabled;   /* leave up/ms/active untouched (unknown until probed) */
		});
		redraw();
	});
}

/* End-to-end exit check state (e2e_status = e2e.json + running flag). Cheap
   (one small file read), so it rides the 5 s stats poll; while a check runs,
   a faster 3 s poll fills in the per-exit verdicts as they finish. */
function refreshE2e() {
	return callE2eStatus().then(function(r) {
		state.e2e = r || { running: false, ts: 0, results: {} };
		if (state.e2e.running) startE2ePoll();
		else                   stopE2ePoll();
		if (e2eBtnEl) {
			e2eBtnEl.disabled = !!state.e2e.running;
			e2eBtnEl.firstChild.nodeValue = state.e2e.running ? _('E2E check running…') : _('Run E2E check');
		}
		redraw();
	}, function() {});
}
var e2ePolling = false;
function startE2ePoll() {
	if (e2ePolling) return;
	poll.add(refreshE2e, 3);
	e2ePolling = true;
}
function stopE2ePoll() {
	if (!e2ePolling) return;
	poll.remove(refreshE2e);
	e2ePolling = false;
}

/* Auto-refresh of the active connectivity probe (per-browser, like the confdir
   dismissal). Off = the page never probes on its own — handy while a suspect
   "blown" exit is under investigation; one-shot checks stay available. */
var PING_AUTO_KEY = 'luci-app-xray-monitor.ping-autorefresh';
var healthPolling = false;
function pingAutoEnabled() {
	try { return localStorage.getItem(PING_AUTO_KEY) !== '0'; } catch (e) { return true; }
}
function startHealthPoll() {
	if (healthPolling) return;
	poll.add(refreshHealth, 30);
	healthPolling = true;
}
function stopHealthPoll() {
	if (!healthPolling) return;
	poll.remove(refreshHealth);
	healthPolling = false;
}

return view.extend({
	load: function() {
		// refreshMeta is probe-free, so toggles + disabled state are ready on first paint;
		// refreshE2e just reads the results file (no traffic, no probe)
		return Promise.all([ refreshStats(), refreshMeta(), refreshE2e() ]).catch(function() {});
	},

	render: function() {
		root = E('div', { 'class': 'cbi-section' });
		redraw();
		poll.add(refreshStats, 5);
		// Connectivity probing only runs when auto-refresh is on (off = don't poke exits)
		if (pingAutoEnabled()) { startHealthPoll(); refreshHealth(); }

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

		var pingNowBtn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Refresh ping now'));
		pingNowBtn.addEventListener('click', function() {
			pingNowBtn.disabled = true;
			refreshHealth().then(function() { pingNowBtn.disabled = false; },
			                     function() { pingNowBtn.disabled = false; });
		});

		/* Kick the end-to-end check (detached server-side) and follow its
		   progress: e2e.json fills in verdict by verdict while it runs. */
		var e2eBtn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Run E2E check'));
		e2eBtnEl = e2eBtn;
		e2eBtn.disabled = !!(state.e2e && state.e2e.running);
		e2eBtn.addEventListener('click', function() {
			e2eBtn.disabled = true;
			callE2eStart().then(function(res) {
				if (!res || !res.ok) {
					e2eBtn.disabled = false;
					ui.addNotification(null, E('p', _('Could not start the E2E check: ') + ((res && res.msg) || _('unknown error'))), 'error');
					return;
				}
				startE2ePoll();
				return refreshE2e();
			}, function() {
				e2eBtn.disabled = false;
				ui.addNotification(null, E('p', _('E2E check call failed.')), 'error');
			});
		});

		var autoCb = E('input', { 'type': 'checkbox' });
		autoCb.checked = pingAutoEnabled();
		autoCb.addEventListener('change', function() {
			try { localStorage.setItem(PING_AUTO_KEY, autoCb.checked ? '1' : '0'); } catch (e) {}
			if (autoCb.checked) { startHealthPoll(); refreshHealth(); }
			else                { stopHealthPoll(); }
		});
		var autoToggle = E('label', {
			'style': 'display:flex;align-items:center;gap:6px;cursor:pointer;margin-left:auto;',
			'title': _('When off, the page never probes exits on its own — use “Refresh ping now” for a one-shot check.')
		}, [ autoCb, E('span', {}, _('Auto-refresh ping (30s)')) ]);

		var bar = E('div', { 'style': 'margin:.5em 0;display:flex;gap:8px;flex-wrap:wrap;align-items:center;' },
			[ updBtn, validateBtn, resetBtn, pingNowBtn, e2eBtn, autoToggle ]);
		return E('div', {}, [ E('h2', {}, _('Xray Monitor')), bar, root ]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
