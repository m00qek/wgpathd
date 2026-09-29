'use strict';
'require view';
'require dom';
'require poll';
'require wgpathd';

// The children of E() are always arrays, so every string lands in a text node;
// see wgpathd.js.

function settingsLink() {
	return E('a', { 'href': L.url('admin/network/wgpathd') }, [ _('Network → Mesh paths') ]);
}

function section(title, descr, content) {
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [ title ]),
		descr ? E('div', { 'class': 'cbi-section-descr' }, descr) : E([], []),
		content
	]);
}

function alertBox(kind, children) {
	return E('div', { 'class': 'alert-message ' + kind }, children);
}

function em(text) {
	return E('em', {}, [ text ]);
}

function keyValueTable(rows) {
	return E('table', { 'class': 'table' }, rows.map(([ key, value ]) =>
		E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '33%' }, [ key ]),
			E('td', { 'class': 'td left' }, value)
		])));
}

function placeholder(columns, children) {
	return E('tr', { 'class': 'tr placeholder' }, [
		E('td', { 'class': 'td', 'colspan': String(columns) }, children)
	]);
}

function table(headers, rows, empty) {
	const titles = E('tr', { 'class': 'tr table-titles' },
		headers.map((h) => E('th', { 'class': 'th' }, [ h ])));

	return E('table', { 'class': 'table' },
		[ titles ].concat(rows.length ? rows : [ placeholder(headers.length, empty) ]));
}

function cell(title, children) {
	return E('td', { 'class': 'td', 'data-title': title }, children);
}

function details(items) {
	return E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:.75em 2.5em' }, items.map(([ key, value ]) =>
		E('div', {}, [ E('strong', {}, [ key ]), E('br'), E('span', {}, value) ])));
}

return view.extend({
	load() {
		return wgpathd.load();
	},

	render(status) {
		this.expanded = new Set();

		const body = E('div', {}, [ this.renderBody(status) ]);

		poll.add(() => wgpathd.status().then((next) => dom.content(body, this.renderBody(next))));

		return E([], [
			E('h2', { 'name': 'content' }, [ _('Mesh paths') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('How each mesh peer is reached right now.'), ' ', _('Settings:'), ' ', settingsLink()
			]),
			body
		]);
	},

	renderBody(status) {
		if (!wgpathd.isRunning(status))
			return alertBox('warning', [
				E('p', {}, [ _('The wgpathd service is not running.') ]),
				E('p', {}, [ _('Enable it and check its settings under'), ' ', settingsLink(), '.' ])
			]);

		if (wgpathd.isSpoke(status))
			return this.renderSpoke(status);

		if (wgpathd.isHub(status))
			return this.renderHub(status);

		return alertBox('warning', wgpathd.fill(_('The wgpathd service reports a role this page does not know: %s'),
			String(status.role)));
	},

	renderSpoke(status) {
		return E([], [
			this.renderAlerts(status),
			section(_('Service'), null, this.renderService(status)),
			section(_('Peers'), null, this.renderPeers(status)),
			section(_('Recent changes'), [
				_('Kept in memory since the service started, most recent first.'), ' ',
				_('Every change is also in the'), ' ',
				E('a', { 'href': L.url('admin/status/logs') }, [ _('system log') ]), '.'
			], this.renderHistory(status))
		]);
	},

	renderAlerts(status) {
		const out = [];
		const discovery = status.discovery ?? {};

		if (status.mode === 'observe')
			out.push(alertBox('notice', [
				_('Observe mode: wgpathd checks the direct paths and logs what it would do, but keeps every peer on the hub path.'),
				' ', _('Switch to steer mode under'), ' ', settingsLink(), '.'
			]));

		if (discovery.fresh === false)
			out.push(alertBox('warning', (discovery.last_ok != null)
				? wgpathd.fill(_('The peer list could not be updated from the hub. Direct tries use the addresses from the last good list, %s old.'),
					wgpathd.duration(status.now - discovery.last_ok))
				: [ _('The peer list has not been fetched from the hub yet. Until it is, direct tries use the addresses saved by an earlier run, if any.') ]));

		return E([], out);
	},

	renderService(status) {
		const discovery = status.discovery ?? {};
		let list;

		if (discovery.fresh && discovery.last_ok != null)
			list = wgpathd.fill(_('Updated %s ago from %s'), wgpathd.duration(status.now - discovery.last_ok), discovery.url);
		else if (discovery.last_ok != null)
			list = wgpathd.fill(_('Update failed; the last good list is %s old. From %s'),
				wgpathd.duration(status.now - discovery.last_ok), discovery.url);
		else
			list = wgpathd.fill(_('Not fetched yet, from %s'), discovery.url);

		return keyValueTable([
			[ _('Mode'), wgpathd.modeText(status.mode) ],
			[ _('Mesh'), wgpathd.fill(_('%s, relaying through %s'), status.mesh_iface, status.hub_iface) ],
			[ _('Peer list'), list ]
		]);
	},

	renderPeers(status) {
		const headers = [ _('Peer'), _('Path'), _('Endpoint'), _('For'), _('Switches'), '' ];
		const router = wgpathd.routerName();
		const peers = wgpathd.peers(status);
		const rows = [];

		if (!peers.length)
			rows.push(placeholder(headers.length, [
				em(_('No peer is steered yet.')), ' ', _('Give peers a relay endpoint and a tunnel address under'), ' ',
				settingsLink(), '.'
			]));

		peers.forEach((peer, i) => {
			const style = 'cbi-rowstyle-' + (1 + i % 2);
			const open = this.expanded.has(peer.pubkey);
			const detailRow = E('tr', { 'class': 'tr ' + style, 'style': open ? '' : 'display:none' }, [
				E('td', { 'class': 'td', 'colspan': String(headers.length) }, [ this.renderDetails(peer, status) ])
			]);
			const button = E('button', {
				'class': 'cbi-button',
				'type': 'button',
				'aria-expanded': String(open),
				'click': (ev) => this.toggle(peer.pubkey, ev.currentTarget, detailRow)
			}, [ open ? _('Hide details') : _('Show details') ]);
			const note = (status.mode !== 'steer' && peer.ready) ? _('Would test direct')
				: (wgpathd.givenUpWait(peer, status.now) != null) ? _('Direct given up')
				: null;
			const extra = note ? [ ' ', E('span', { 'class': 'label' }, [ note ]) ] : [];

			rows.push(E('tr', { 'class': 'tr ' + style }, [
				cell(headers[0], [ E('strong', {}, [ peer.section ]) ]),
				cell(headers[1], [
					E('div', { 'style': 'margin-bottom:.4em' }, [ wgpathd.stateLabel(peer.state) ].concat(extra)),
					wgpathd.pathStrip(router, peer.section, peer.state)
				]),
				cell(headers[2], [ peer.endpoint ?? em(_('Not set yet')) ]),
				cell(headers[3], [ wgpathd.duration(status.now - peer.since) ]),
				cell(headers[4], [ String(peer.switches) ]),
				E('td', { 'class': 'td cbi-section-actions' }, [ button ])
			]));
			rows.push(detailRow);
		});

		(status.unmanaged ?? []).forEach((u) => {
			rows.push(E('tr', { 'class': 'tr', 'style': 'opacity:.6' }, [
				cell(headers[0], [ E('strong', {}, [ u.section ]) ]),
				cell(headers[1], [ E('span', { 'class': 'label' }, [ _('Not steered') ]) ]),
				E('td', { 'class': 'td', 'colspan': String(headers.length - 2) }, wgpathd.unmanagedText(u.reason))
			]));
		});

		return table(headers, rows);
	},

	toggle(key, button, row) {
		const open = !this.expanded.has(key);

		if (open)
			this.expanded.add(key);
		else
			this.expanded.delete(key);

		row.style.display = open ? '' : 'none';
		button.setAttribute('aria-expanded', String(open));
		dom.content(button, [ open ? _('Hide details') : _('Show details') ]);
	},

	renderDetails(peer, status) {
		const now = status.now;
		const params = status.params;
		const hubAnswers = [ _('Answers that came through the hub'), [ String(peer.relayed_answers) ] ];

		switch (peer.state) {
		case 'RELAY':
			return details([
				[ _('Direct address last tried'), [ peer.last_target ?? em(_('None yet')) ] ],
				[ _('Direct address the hub publishes'), [ peer.candidate ?? em(_('None')) ] ],
				...((peer.candidate_refused != null)
					? [ [ _('Why it is not tried'), wgpathd.refusalText(peer.candidate_refused) ] ]
					: []),
				[ _('Why it uses the hub'), wgpathd.fallbackText(peer, params) ],
				(status.mode === 'steer')
					? [ _('Next direct try'), wgpathd.nextTrialText(peer, now, params) ]
					: [ _('Would test direct'), wgpathd.readinessText(peer, now, params) ],
				hubAnswers
			]);

		case 'TRIALING':
			return details([
				[ _('Direct address under test'), [ peer.target ?? em(_('None')) ] ],
				[ _('Test ends in'), (peer.trial_deadline != null && peer.trial_deadline > now)
					? [ wgpathd.duration(peer.trial_deadline - now) ]
					: [ _('Any moment now') ] ],
				hubAnswers
			]);

		case 'DIRECT':
			return details([
				[ _('Direct address'), [ peer.target ?? peer.endpoint ?? em(_('None')) ] ],
				[ _('Checks without an answer'),
					[ _('%d of %d before it goes back to the hub').format(peer.down_streak, params.m_down) ] ],
				hubAnswers
			]);

		default:
			return details([ hubAnswers ]);
		}
	},

	renderHistory(status) {
		const history = status.history ?? [];

		return table([ _('Time'), _('Peer'), _('Change') ], history.map((entry, i) =>
			E('tr', { 'class': 'tr cbi-rowstyle-' + (1 + i % 2) }, [
				cell(_('Time'), [
					wgpathd.clockTime(status.now, entry.ts), ' ',
					E('small', {}, [ '(' ].concat(wgpathd.ago(status.now, entry.ts), [ ')' ]))
				]),
				cell(_('Peer'), [ entry.section ]),
				cell(_('Change'), wgpathd.changeText(entry, status.params))
			])), [ em(_('No changes since the service started.')) ]);
	},

	renderHub(status) {
		const url = wgpathd.publishedURL();
		const headers = [ _('Peer'), _('Public key'), _('Direct address'), _('Last heard') ];
		const named = Object.keys(status.peers).map((key) => ({ key: key, name: wgpathd.sectionOf(key) }));

		// By name, then those without one.
		named.sort((a, b) => (a.name == null) - (b.name == null) || String(a.name ?? a.key).localeCompare(String(b.name ?? b.key)));

		const rows = named.map(({ key, name }, i) => {
			const peer = status.peers[key];
			const age = peer.handshake_age;
			const stale = (age == null || age > wgpathd.SESSION_LIFETIME);
			const attrs = { 'class': 'tr cbi-rowstyle-' + (1 + i % 2) };

			if (stale)
				attrs.style = 'opacity:.6';

			return E('tr', attrs, [
				cell(headers[0], [ name ?? em(_('Unknown')) ]),
				cell(headers[1], [ E('code', {}, [ key.substring(0, 8) + '…' ]) ]),
				cell(headers[2], [ peer.direct ]),
				cell(headers[3], (age != null) ? wgpathd.fill(_('%s ago'), wgpathd.duration(age)) : [ em(_('Never')) ])
			]);
		});

		return E([], [
			E('p', {}, [ _('This router is the hub. It publishes the direct address of each spoke, so the spokes can reach each other directly, and relays their traffic while a direct path fails.') ]),
			section(_('Published peers'), url
				? wgpathd.fill(_('Spokes fetch this list from %s. A peer not heard from for more than 3 minutes has no current WireGuard session.'), url)
				: [ _('A peer not heard from for more than 3 minutes has no current WireGuard session.') ],
				table(headers, rows, [ em(_('No spoke has a direct IPv6 address yet.')) ]))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
