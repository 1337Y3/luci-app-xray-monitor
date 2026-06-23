'use strict';
'require view';
'require rpc';
'require poll';

var callStats = rpc.declare({ object: 'xray-monitor', method: 'stats' });

var MAX  = 120;    /* samples kept (~10 min at 5s) */
var prev = null;   /* { ts, flat } */
var hist = {};     /* tag -> [{down, up}] (bytes/s) */
var root = null;

function fmtBytes(n) {
	n = Number(n) || 0;
	var u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'], i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return (i ? n.toFixed(2) : n.toFixed(0)) + ' ' + u[i];
}
function fmtRate(n) { return fmtBytes(n) + '/s'; }

function parseOut(reply) {
	var stat = (reply && reply.stat) ? reply.stat : [], flat = {};
	for (var i = 0; i < stat.length; i++) {
		var p = String(stat[i].name || '').split('>>>');
		if (p.length !== 4 || p[0] !== 'outbound') continue;
		flat['outbound/' + p[1] + '/' + p[3]] = Number(stat[i].value || 0);
	}
	return flat;
}

function svgChart(series) {
	var w = 320, h = 80, pad = 3, n = series.length;
	var open = '<svg viewBox="0 0 ' + w + ' ' + h + '" preserveAspectRatio="none" ' +
	           'style="width:100%;height:80px;background:#0b1f33;border-radius:4px;display:block;">';
	if (n < 2) return open + '</svg>';
	var max = 1;
	series.forEach(function(s) { if (s.down > max) max = s.down; if (s.up > max) max = s.up; });
	function poly(key, color) {
		var pts = series.map(function(s, i) {
			var x = pad + i * (w - 2 * pad) / (n - 1);
			var y = h - pad - (s[key] / max) * (h - 2 * pad);
			return x.toFixed(1) + ',' + y.toFixed(1);
		}).join(' ');
		return '<polyline fill="none" stroke="' + color + '" stroke-width="1.5" points="' + pts + '"/>';
	}
	return open + poly('down', '#3b9dff') + poly('up', '#43d17a') + '</svg>';
}

function card(tag) {
	var s = hist[tag] || [];
	var cur = s.length ? s[s.length - 1] : { down: 0, up: 0 };
	var peak = 0;
	s.forEach(function(x) { if (x.down > peak) peak = x.down; if (x.up > peak) peak = x.up; });

	var head = E('div', { 'style': 'display:flex;justify-content:space-between;align-items:baseline;margin-bottom:3px;' }, [
		E('strong', {}, tag),
		E('span', { 'style': 'font-size:90%;' }, [
			E('span', { 'style': 'color:#3b9dff;' }, '↓ ' + fmtRate(cur.down)),
			E('span', {}, '  '),
			E('span', { 'style': 'color:#43d17a;' }, '↑ ' + fmtRate(cur.up))
		])
	]);
	var chartDiv = E('div', {});
	chartDiv.innerHTML = svgChart(s);
	var foot = E('div', { 'style': 'color:#888;font-size:85%;margin-top:2px;' }, _('peak') + ' ' + fmtRate(peak));

	return E('div', {
		'style': 'flex:1 1 320px;min-width:300px;margin:6px;padding:8px;' +
		         'border:1px solid rgba(128,128,128,.25);border-radius:6px;'
	}, [ head, chartDiv, foot ]);
}

function redraw() {
	if (!root) return;
	var tags = Object.keys(hist).sort();
	var legend = E('div', { 'style': 'margin-bottom:.5em;color:#888;' }, [
		E('span', { 'style': 'color:#3b9dff;font-weight:bold;' }, '↓ ' + _('download')),
		E('span', {}, '    '),
		E('span', { 'style': 'color:#43d17a;font-weight:bold;' }, '↑ ' + _('upload')),
		E('span', {}, '    — ' + _('rolling ~10 min, 5s resolution'))
	]);
	var body = tags.length
		? E('div', { 'style': 'display:flex;flex-wrap:wrap;' }, tags.map(card))
		: E('em', {}, _('Collecting data… charts appear after a few seconds.'));

	while (root.firstChild) root.removeChild(root.firstChild);
	root.appendChild(legend);
	root.appendChild(body);
}

function refresh() {
	return callStats().then(function(r) {
		var flat = parseOut(r);
		var now = Date.now();
		var dt = prev ? (now - prev.ts) / 1000 : 0;
		var tags = {};
		Object.keys(flat).forEach(function(k) { tags[k.split('/')[1]] = 1; });

		if (prev && dt > 0) {
			Object.keys(tags).forEach(function(tag) {
				var dn = flat['outbound/' + tag + '/downlink'] || 0;
				var up = flat['outbound/' + tag + '/uplink'] || 0;
				var pdn = prev.flat['outbound/' + tag + '/downlink'];
				var pup = prev.flat['outbound/' + tag + '/uplink'];
				var dRate = (pdn !== undefined) ? Math.max(0, (dn - pdn) / dt) : 0;
				var uRate = (pup !== undefined) ? Math.max(0, (up - pup) / dt) : 0;
				if (!hist[tag]) hist[tag] = [];
				hist[tag].push({ down: dRate, up: uRate });
				if (hist[tag].length > MAX) hist[tag].shift();
			});
		} else {
			/* seed tag list so cards show immediately */
			Object.keys(tags).forEach(function(tag) { if (!hist[tag]) hist[tag] = []; });
		}
		prev = { ts: now, flat: flat };
		redraw();
	});
}

return view.extend({
	load: function() { return refresh().catch(function() {}); },

	render: function() {
		root = E('div', { 'class': 'cbi-section' });
		redraw();
		poll.add(refresh, 5);
		return E('div', {}, [ E('h2', {}, _('Xray Graphs — per-outbound throughput')), root ]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
