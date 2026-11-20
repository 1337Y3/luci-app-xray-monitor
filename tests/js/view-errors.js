'use strict';
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture(name) {
	const elements = [], errors = [], notices = [], replies = {}, modals = [], timers = [];
	function E(tag, attrs, children) {
		if (children === undefined && typeof attrs === 'string') { children = attrs; attrs = {}; }
		const el = { tag, attrs: attrs || {}, children, value: children || '', disabled: false,
			addEventListener(event, fn) { this[event] = fn; }, appendChild() {}, parentNode: { replaceChild() {} } };
		Object.assign(el, el.attrs);
		elements.push(el); return el;
	}
	const source = fs.readFileSync(path.join(process.argv[2], 'files/www/luci-static/resources/view/xray', name + '.js'), 'utf8');
	const view = new Function('rpc', 'view', 'poll', 'ui', 'XrayDiff', 'XrayErrors', 'E', '_', 'document', 'localStorage', 'window', 'confirm', source)(
		{ declare: ({ method }) => () => replies[method] instanceof Error ? Promise.reject(replies[method]) : Promise.resolve(replies[method]) },
		{ extend: o => o }, { add() {}, remove() {} },
		{ addNotification: (...args) => notices.push(args), showModal: (...args) => modals.push(args), hideModal() {} },
		{ renderSemantic: () => E('div'), renderUnified: () => E('div') }, { show: (message, cause) => {
			assert.strictEqual(typeof message, 'string');
			errors.push(message + (cause == null ? '' : '\n' + ((cause && (cause.message || cause.msg)) || String(cause))));
		} },
		E, s => s, { createTextNode: s => s }, { getItem: () => '0' }, { setTimeout: fn => timers.push(fn) }, () => true);
	return { view, elements, errors, notices, replies, modals, timers,
		button: label => elements.find(e => e.tag === 'button' && e.children === label) };
}
(async function() {
	const reason = '<tag>\nbackend detail';
	const c = fixture('config'); c.view.render({ config: '{}', hash: 'a' });
	c.replies.config_test = { ok: false, msg: reason };
	c.button('Test config').click(); await tick();
	assert(c.errors[0].includes(reason)); assert.strictEqual(c.button('Test config').disabled, false);
	c.replies.config_test = { ok: true }; c.replies.config_diff_text = new Error(reason);
	c.button('Save & apply').click(); await tick();
	assert(c.errors[1].includes(reason)); assert.strictEqual(c.button('Save & apply').disabled, false);
	c.replies.config_diff_text = {}; c.replies.config_get = { config: '{}', hash: 'a' };
	c.button('Save & apply').click(); await tick();
	assert.strictEqual(c.modals.length, 1);
	c.replies.config_save = new Error(reason);
	c.button('Apply anyway').click(); await tick();
	assert.strictEqual(c.errors.length, 2, 'existing preview keeps its own inline save error');
	assert.strictEqual(c.button('Apply anyway').disabled, false);
	assert.strictEqual(c.button('Keep editing').disabled, false);
	const m = fixture('monitor'); m.view.render();
	m.replies.update_check = { installed: '1', latest: '2', update_available: true };
	m.replies.update_apply = { ok: false, msg: reason };
	m.button('Check for updates').click(); await tick();
	assert(m.errors[0].includes(reason)); assert.strictEqual(m.timers.length, 0, 'failed update does not reload');
	assert.strictEqual(m.notices.length, 0, 'failed update does not claim success');
	m.replies.config_test = new Error(reason);
	// Overview uses the validate RPC rather than editor content testing.
	m.replies.validate = new Error(reason);
	m.button('Validate config').click(); await tick();
	assert(m.errors[1].includes(reason)); assert.strictEqual(m.button('Validate config').disabled, false);
	const b = fixture('backups'); b.view.render({ backups: [] });
	b.replies.backups_list = new Error(reason);
	const refresh = b.button('Refresh'); refresh.click(); await tick();
	assert(b.errors[0].includes(reason)); assert.strictEqual(refresh.disabled, false);
	console.log('PASS config/monitor/backup action errors preserve details and recover controls');
})().catch(error => { console.error(error); process.exit(1); });
