'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const root = process.argv[2];
class Node {
	constructor(tag, attrs = {}, children = []) {
		this.tag = tag; this.attrs = attrs || {}; this.children = []; this.events = {};
		this.value = this.attrs.value || ''; this.checked = this.attrs.checked != null;
		this.classes = new Set((this.attrs.class || '').split(' '));
		this.classList = { contains: c => this.classes.has(c), add: c => this.classes.add(c), remove: c => this.classes.delete(c) };
		[].concat(children == null ? [] : children).forEach(c => this.appendChild(c));
	}
	get firstChild() { return this.children[0]; }
	get firstElementChild() { return this.children.find(c => c instanceof Node); }
	get isConnected() { return true; }
	appendChild(c) { if (c.parentNode) c.parentNode.removeChild(c); this.children.push(c); if (c instanceof Node) c.parentNode = this; return c; }
	removeChild(c) { this.children.splice(this.children.indexOf(c), 1); c.parentNode = null; }
	replaceChild(n, old) { const i = this.children.indexOf(old); this.children[i] = n; old.parentNode = null; n.parentNode = this; }
	addEventListener(n, fn) { this.events[n] = fn; }
	click() { if (this.events.click) return this.events.click(); }
	focus() { doc.activeElement = this; }
	showModal() { this.previousFocus = doc.activeElement; this.open = true; }
	close() { this.open = false; if (this.previousFocus) this.previousFocus.focus(); if (this.events.close) this.events.close(); }
	remove() { if (this.parentNode) this.parentNode.removeChild(this); }
}
const E = (tag, attrs, children) => new Node(tag, attrs, children);
const doc = { body: E('body'), createTextNode: text => ({ text }), getElementById: () => overlay };
const overlay = E('div', {}, E('div', { class: 'modal' }));
const notices = [], errors = [];
const ui = {
	showModal(title, children) {
		const dialog = overlay.firstElementChild;
		// Match LuCI 23.05's destructive singleton-dialog behavior.
		dialog.classes = new Set(['modal']);
		while (dialog.firstChild) dialog.removeChild(dialog.firstChild);
		dialog.appendChild(E('h4', {}, title)); children.forEach(c => dialog.appendChild(c));
		doc.body.classList.add('modal-overlay-active'); overlay.focus(); return dialog;
	},
	hideModal() { doc.body.classList.remove('modal-overlay-active'); },
	addNotification(...args) { notices.push(args); }
};
function text(n) { return typeof n === 'string' ? n : n.text || (n.children || []).map(text).join(''); }
function all(n) { return [n].concat((n.children || []).filter(c => c instanceof Node).flatMap(all)); }
function button(n, label) { return all(n).find(c => c.tag === 'button' && text(c) === label); }
const helper = new Function('baseclass', 'ui', 'E', '_', 'document', fs.readFileSync(path.join(root, 'files/www/luci-static/resources/xray-errors.js'), 'utf8'))({ extend: o => o }, ui, E, s => s, doc);
const editor = E('input', { value: 'unsaved password' });
ui.showModal('Editor', [editor, E('div', { class: 'right' }, E('button', {}, 'Cancel'))]);
const original = overlay.firstElementChild; editor.focus(); overlay.scrollTop = 52;
helper.show('<img src=x onerror=alert(1)>\nbackend detail');
const error = doc.body.children.find(n => n.tag === 'dialog');
assert.notStrictEqual(error, original);
assert.strictEqual(error.tag, 'dialog');
assert.strictEqual(error.open, true);
assert.strictEqual(overlay.firstElementChild, original);
assert(text(error).includes('<img src=x onerror=alert(1)>\nbackend detail'));
assert(!all(error).some(n => n.tag === 'img'), 'backend markup stays text');
helper.show('another failure'); helper.show('another failure');
helper.show('Request failed', new Error('timeout'));
assert(text(error).includes('Request failed\ntimeout'));
assert.strictEqual(text(error).split('another failure').length, 2, 'concurrent errors append without duplicates');
assert.strictEqual(all(error).find(n => n.attrs.id === 'xray-error-details').attrs.style.includes('pre-wrap'), true);
button(error, 'Close').click(); // Native Escape follows the same close event cleanup.
assert.strictEqual(overlay.firstElementChild, original);
assert.strictEqual(editor.value, 'unsaved password');
assert(doc.body.classList.contains('modal-overlay-active'));
assert.strictEqual(doc.activeElement, editor);
assert.strictEqual(overlay.scrollTop, 52);
ui.hideModal(); helper.show('No editor'); button(doc.body.children.find(n => n.tag === 'dialog'), 'Close').click();
assert(!doc.body.classList.contains('modal-overlay-active'));

helper.show('Async failure');
ui.showModal('Unrelated confirm', [E('button', {}, 'Confirm')]);
button(doc.body.children.find(n => n.tag === 'dialog'), 'Close').click();
assert.strictEqual(text(overlay.firstElementChild), 'Unrelated confirmConfirm');
helper.show('Another async failure'); ui.hideModal();
button(doc.body.children.find(n => n.tag === 'dialog'), 'Close').click();
assert(!doc.body.classList.contains('modal-overlay-active'));

function view(name) {
	let response = { ok: false, msg: 'backend failed' };
	let gets = 0; const getReplies = [];
	let state = name === 'mieru' ? { binary: {}, instances: [], tests: {} } : { subscriptions: [{ id: 's1', prefix: 'work', enabled: true }], servers: [], diff: {} };
	const source = fs.readFileSync(path.join(root, 'files/www/luci-static/resources/view/xray/' + name + '.js'), 'utf8');
	const rpc = { declare: ({ method }) => () => {
		if (method.endsWith('_get')) {
			gets++; const next = getReplies.length ? getReplies.shift() : state;
			return next instanceof Error ? Promise.reject(next) : Promise.resolve(next);
		}
		return response instanceof Error ? Promise.reject(response) : Promise.resolve(response);
	} };
	const api = new Function('rpc', 'view', 'poll', 'ui', 'XrayDiff', 'XrayErrors', 'E', '_', 'document', 'confirm', source)(rpc, { extend: o => o }, { add() {} }, ui, {}, { show: m => { errors.push(m); helper.show(m); } }, E, s => s, doc, () => true);
	return { api, response: value => { response = value; }, state: value => { state = value; }, getCount: () => gets, queueGet: value => getReplies.push(value) };
}
const tick = () => new Promise(resolve => setImmediate(resolve));
(async () => {
	const m = view('mieru'); await m.api.load();
	const page = m.api.render(); button(page, 'Add connection').click();
	const form = overlay.firstElementChild;
	const inputs = all(form).filter(n => n.tag === 'input');
	const values = ['work', '1.2.3.4', '', '2027/tcp', 'user', 'secret', '1400', '1080', '', ''];
	inputs.forEach((n, i) => { n.value = values[i]; });
	const beforeFailure = m.getCount();
	button(form, 'Add').click(); await tick();
	assert.strictEqual(m.getCount(), beforeFailure + 1, 'backend action failure still refreshes state');
	assert(errors.includes('backend failed'));
	button(doc.body.children.find(n => n.tag === 'dialog'), 'Close').click();
	assert.strictEqual(overlay.firstElementChild, form, 'failed save restores same form');
	assert.strictEqual(inputs[5].value, 'secret');
	m.response(new Error('RPC unavailable'));
	button(form, 'Add').click(); await tick();
	assert(errors.includes('RPC unavailable'));
	button(doc.body.children.find(n => n.tag === 'dialog'), 'Close').click(); ui.hideModal();

	const pristine = view('subscription'); await pristine.api.load(); const cleanPage = pristine.api.render();
	pristine.state({ subscriptions: [{ id: 's1', prefix: 'external', enabled: true }], servers: [], diff: {}, cron_schedule: '0 4 * * *' });
	await pristine.api.load();
	assert(all(cleanPage).some(n => n.tag === 'input' && n.value === 'external'), 'pristine rows reflect external changes');
	assert(all(cleanPage).some(n => n.tag === 'input' && n.value === '0 4 * * *'), 'pristine settings reflect external changes');
	const s = view('subscription'); await s.api.load(); const subscription = s.api.render();
	const fields = all(subscription).filter(n => n.tag === 'input'); fields[0].value = 'edited'; fields[1].value = 'https://secret/new';
	button(subscription, 'Save').click(); await tick();
	button(doc.body.children.find(n => n.tag === 'dialog'), 'Close').click();
	assert.strictEqual(fields[1].value, 'https://secret/new');
	// Success elsewhere refreshes status, retaining the other live input nodes.
	s.response({ ok: true }); button(subscription, 'Fetch now').click(); await tick();
	assert(all(subscription).includes(fields[0])); assert.strictEqual(fields[0].value, 'edited');
	s.response(new Error('subscription RPC unavailable'));
	s.queueGet(new Error('resync unavailable')); const beforeResync = s.getCount();
	button(subscription, 'Save').click(); await tick();
	assert(errors.includes('subscription RPC unavailable'));
	assert(errors.includes('resync unavailable'));
	assert.strictEqual(s.getCount(), beforeResync + 1, 'failed resync is displayed without a refresh loop');
	console.log('PASS error modal text safety, concurrent errors, dialog restoration, Mieru save failures, Subscription edits and RPC errors');
})().catch(e => { console.error(e); process.exit(1); });
