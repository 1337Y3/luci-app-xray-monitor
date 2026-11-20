'use strict';
'require baseclass';

var active = null;

return baseclass.extend({
	show: function(message, cause) {
		message = String(message || _('error'));
		if (cause != null) message += '\n' + ((cause && (cause.message || cause.msg)) || String(cause));
		if (active && active.dialog.open) {
			if (active.messages.indexOf(message) < 0) {
				active.messages.push(message);
				active.details.appendChild(E('p', {}, document.createTextNode(message)));
			}
			return;
		}

		// A native top-layer dialog leaves LuCI's singleton editor/confirm intact,
		// even when an unrelated asynchronous action opens or closes that modal.
		var dialog = E('dialog', { 'class': 'modal', 'aria-label': _('Error'),
			'aria-describedby': 'xray-error-details',
			'style': 'display:block;position:fixed;visibility:visible;opacity:1;transform:none;margin:auto;width:90%;max-width:600px;max-height:80vh;overflow:auto;' });
		var details = E('div', { 'id': 'xray-error-details', 'aria-live': 'assertive',
			'style': 'white-space:pre-wrap;overflow-wrap:anywhere;' }, E('p', {}, document.createTextNode(message)));
		var close = E('button', { 'class': 'btn', 'type': 'button', 'autofocus': '' }, _('Close'));
		var current = { dialog: dialog, details: details, messages: [ message ] };
		close.addEventListener('click', function() { dialog.close(); });
		dialog.addEventListener('close', function() {
			if (active === current) active = null;
			dialog.remove();
		});
		dialog.appendChild(E('h4', {}, _('Error')));
		dialog.appendChild(details);
		dialog.appendChild(E('div', { 'class': 'right' }, close));
		document.body.appendChild(dialog);
		active = current;
		dialog.showModal();
		close.focus();
	}
});
