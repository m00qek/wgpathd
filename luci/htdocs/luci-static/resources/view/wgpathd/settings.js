'use strict';
'require view';
'require form';
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
		const m = new form.Map('wgpathd', _('Mesh paths'),
			_('How wgpathd chooses between the direct path and the hub relay for each WireGuard mesh peer.'));

		return m.render().then((node) => {
			if (!L.isObject(status))
				node.querySelector('.cbi-map-descr').after(
					E('div', { 'class': 'alert-message warning' }, _('The wgpathd service is not running.')));

			return node;
		});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
