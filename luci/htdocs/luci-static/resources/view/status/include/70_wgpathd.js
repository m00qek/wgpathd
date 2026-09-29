'use strict';
'require baseclass';
'require wgpathd';

// The Mesh paths section of Status → Overview. Returning null keeps the section
// hidden: the service is not running, is a hub, or steers no peer.

return baseclass.extend({
	title: _('Mesh paths'),

	load() {
		return wgpathd.load();
	},

	render(status) {
		if (!wgpathd.isSpoke(status) || !Object.keys(status.peers).length)
			return null;

		const router = wgpathd.routerName();
		const headers = [ _('Peer'), _('Path'), _('Now') ];
		const rows = wgpathd.peers(status).map((peer, i) =>
			E('tr', { 'class': 'tr cbi-rowstyle-' + (1 + i % 2) }, [
				E('td', { 'class': 'td', 'data-title': headers[0] }, [ peer.section ]),
				E('td', { 'class': 'td', 'data-title': headers[1] }, [ wgpathd.pathStrip(router, peer.section, peer.state) ]),
				E('td', { 'class': 'td', 'data-title': headers[2] }, [
					wgpathd.stateLabel(peer.state), ' ', E('small', {}, wgpathd.summaryText(peer, status))
				])
			]));

		return E([], [
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, headers.map((h) => E('th', { 'class': 'th' }, [ h ])))
			].concat(rows)),
			E('p', {}, [ E('a', { 'href': L.url('admin/status/wgpathd') }, [ _('Details') ]) ])
		]);
	}
});
