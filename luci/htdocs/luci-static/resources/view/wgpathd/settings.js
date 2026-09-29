'use strict';
'require view';
'require form';
'require wgpathd';

return view.extend({
	load() {
		return wgpathd.status();
	},

	render(status) {
		const m = new form.Map('wgpathd', _('Mesh paths'),
			_('How wgpathd chooses between the direct path and the hub relay for each WireGuard mesh peer.'));

		return m.render().then((node) => {
			if (!wgpathd.isRunning(status))
				node.querySelector('.cbi-map-descr').after(
					E('div', { 'class': 'alert-message warning' }, [ _('The wgpathd service is not running.') ]));

			return node;
		});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
