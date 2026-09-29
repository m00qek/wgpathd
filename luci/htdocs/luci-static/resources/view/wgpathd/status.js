'use strict';
'require view';
'require rpc';

const callStatus = rpc.declare({
	object: 'wgpathd',
	method: 'status'
});

return view.extend({
	load() {
		return L.resolveDefault(callStatus(), null);
	},

	render(status) {
		const running = L.isObject(status);

		return E([], [
			E('h2', { 'name': 'content' }, _('Mesh paths')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Which path each WireGuard mesh peer uses right now: direct or through the hub relay.')),
			running
				? E('p', {}, _('The wgpathd service is running as %s.').format(status.role))
				: E('div', { 'class': 'alert-message warning' }, _('The wgpathd service is not running.'))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
