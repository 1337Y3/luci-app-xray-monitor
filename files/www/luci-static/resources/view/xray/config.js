'use strict';
'require view';
'require rpc';
'require ui';

var callGet  = rpc.declare({ object: 'xray-monitor', method: 'config_get' });
var callTest = rpc.declare({ object: 'xray-monitor', method: 'config_test', params: [ 'config' ] });
var callSave = rpc.declare({ object: 'xray-monitor', method: 'config_save', params: [ 'config' ] });

var ta = null;     // the textarea
var pathLabel = null;

function setBusy(btns, on) { btns.forEach(function(b) { b.disabled = on; }); }

return view.extend({
	load: function() { return callGet().catch(function() { return {}; }); },

	render: function(data) {
		ta = E('textarea', {
			'class': 'cbi-input-textarea',
			'style': 'width:100%;min-height:60vh;font-family:monospace;white-space:pre;overflow-wrap:normal;',
			'spellcheck': 'false', 'wrap': 'off'
		}, (data && data.config) ? data.config : '');

		pathLabel = E('code', {}, (data && data.path) ? data.path : '/etc/xray/config.json');

		var testBtn   = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Test config'));
		var saveBtn   = E('button', { 'class': 'cbi-button cbi-button-save important' }, _('Save & apply'));
		var reloadBtn = E('button', { 'class': 'cbi-button cbi-button-neutral' }, _('Reload from disk'));
		var btns = [ testBtn, saveBtn, reloadBtn ];

		testBtn.addEventListener('click', function() {
			setBusy(btns, true);
			callTest(ta.value).then(function(res) {
				setBusy(btns, false);
				if (res && res.ok)
					ui.addNotification(null, E('p', _('xray -test: ') + (res.msg || 'OK')), 'info');
				else
					ui.addNotification(null, E('p', [ E('strong', {}, _('xray -test failed: ')), document.createTextNode((res && res.msg) || _('unknown error')) ]), 'error');
			}, function() { setBusy(btns, false); ui.addNotification(null, E('p', _('Test call failed.')), 'error'); });
		});

		saveBtn.addEventListener('click', function() {
			if (!confirm(_('Validate, back up, write config.json and restart xray now?'))) return;
			setBusy(btns, true);
			callSave(ta.value).then(function(res) {
				setBusy(btns, false);
				if (res && res.ok) ui.addNotification(null, E('p', _('Saved and restarted xray. ') + (res.msg || '')), 'info');
				else ui.addNotification(null, E('p', [ E('strong', {}, _('Save failed (not applied): ')), document.createTextNode((res && res.msg) || _('unknown error')) ]), 'error');
			}, function() { setBusy(btns, false); ui.addNotification(null, E('p', _('Save call failed.')), 'error'); });
		});

		reloadBtn.addEventListener('click', function() {
			setBusy(btns, true);
			callGet().then(function(res) {
				setBusy(btns, false);
				ta.value = (res && res.config) ? res.config : '';
				ui.addNotification(null, E('p', _('Reloaded from disk.')), 'info');
			}, function() { setBusy(btns, false); });
		});

		return E('div', {}, [
			E('h2', {}, _('Xray Config')),
			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, [ _('Editing '), pathLabel, _('. '),
					E('strong', {}, _('Test config')), _(' runs xray -test on the editor contents without saving. '),
					E('strong', {}, _('Save & apply')), _(' validates, backs up (config.json.bak.manual.*), writes, and restarts xray — and rolls back automatically if the test fails.') ]),
				ta,
				E('div', { 'style': 'margin-top:.6em;display:flex;gap:8px;' }, [ testBtn, saveBtn, reloadBtn ])
			])
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
