'use strict';
// Exercise the real view's refresh and install button through LuCI-shaped stubs.
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const source = fs.readFileSync(path.join(process.argv[2], 'files/www/luci-static/resources/view/xray/mieru.js'), 'utf8');
function fixture() {
	let status = { binary: {}, instances: [], install_result: null };
	let response = { ok: true };
	const notices = [];
	const getReplies = [];
	const elements = [];
	function E(tag, attrs, children) {
		const el = { tag, attrs, children, addEventListener(name, fn) { this[name] = fn; }, appendChild() {} };
		elements.push(el);
		return el;
	}
	const api = new Function('rpc', 'view', 'poll', 'ui', 'XrayDiff', 'E', '_', 'document',
		source.replace('return view.extend({', 'return { refresh: refresh, card: buildBinaryCard, view: view.extend({').replace(/\}\);\s*$/, '}) };'));
	return { api: api({ declare: ({ method }) => () => Promise.resolve(method === 'mieru_get' ? (getReplies.length ? getReplies.shift() : status) : response) },
		{ extend: o => o }, {}, { addNotification: (...args) => notices.push(args) }, {}, E, s => s,
		{ createTextNode: s => s }), notices, elements,
		queueGet: p => getReplies.push(p),
		setStatus: v => { status = v; }, setResponse: v => { response = v; } };
}
(async function() {
	for (const ok of [true, false]) {
		const f = fixture();
		await f.api.refresh();
		f.api.card();
		const button = f.elements.find(e => e.tag === 'button' && e.children === 'Install binary');
		f.setStatus({ binary: { installing: 0 }, instances: [], install_result: { ts: 1, ok, msg: 'fast outcome' } });
		button.click();
		await new Promise(resolve => setImmediate(resolve));
		assert.strictEqual(f.notices.length, 2, 'fast completion is surfaced without observing running');
		assert.strictEqual(f.notices[1][2], ok ? 'info' : 'error');
		await f.api.refresh();
		assert.strictEqual(f.notices.length, 2, 'terminal notification appears once');
	}
	const f = fixture();
	await f.api.refresh();
	f.api.card();
	f.setResponse({ ok: true, running: true });
	f.setStatus({ binary: { installing: 1 }, instances: [] });
	f.elements.find(e => e.tag === 'button' && e.children === 'Install binary').click();
	await new Promise(resolve => setImmediate(resolve));
	assert(JSON.stringify(f.notices).includes('already running'), 'existing install gets a distinct message');
	assert(!JSON.stringify(f.notices).includes('Download started'));
	const race = fixture();
	await race.api.refresh();
	race.api.card();
	let resolveOld, resolveNew;
	race.queueGet(new Promise(resolve => { resolveOld = resolve; }));
	const oldRefresh = race.api.refresh();
	race.queueGet(new Promise(resolve => { resolveNew = resolve; }));
	race.elements.find(e => e.tag === 'button' && e.children === 'Install binary').click();
	await new Promise(resolve => setImmediate(resolve));
	resolveOld({ binary: {}, instances: [], install_result: { ts: 1, ok: false, msg: 'stale outcome' } });
	await oldRefresh;
	assert.strictEqual(race.notices.length, 1, 'pre-install poll cannot consume the pending outcome');
	resolveNew({ binary: {}, instances: [], install_result: { ts: 2, ok: true, msg: 'current outcome' } });
	await new Promise(resolve => setImmediate(resolve));
	assert.strictEqual(race.notices.length, 2);
	assert(!JSON.stringify(race.notices).includes('stale outcome'));
	const ordered = fixture();
	ordered.setStatus({ binary: { installing: 1 }, instances: [] });
	await ordered.api.refresh();
	let resolveRunning;
	ordered.queueGet(new Promise(resolve => { resolveRunning = resolve; }));
	const late = ordered.api.refresh();
	ordered.setStatus({ binary: {}, instances: [], install_result: { ts: 3, ok: true, msg: 'done' } });
	await ordered.api.refresh();
	resolveRunning({ binary: { installing: 1 }, instances: [] });
	await late;
	await ordered.api.refresh();
	assert.strictEqual(ordered.notices.length, 1, 'out-of-order polls cannot resurrect a completed install');
	console.log('PASS mieru fast outcomes, already-running response, stale and out-of-order polls');
})().catch(e => { console.error(e); process.exit(1); });
