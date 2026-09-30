'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require ui';
'require dom';
'require wgpathd';

// Network → Mesh paths: /etc/config/wgpathd as a form. The Peers tab lists the peers
// of the mesh interface, each with the `peer` section of its public key; the Timing tab
// has one field per parameter the daemon reports. Save & Apply first checks the form's
// values with `wgpathd.config check`, and applies nothing if a finding fails.
//
// Peer names and descriptions, interface names and the check's messages and firewall
// rules come from the router: they reach E() only inside arrays, and never a form title
// or description, which LuCI renders as markup.

const callCheck = rpc.declare({
	object: 'wgpathd.config',
	method: 'check',
	params: [ 'candidate' ]
});

const callSchema = rpc.declare({
	object: 'wgpathd.config',
	method: 'schema'
});

const LEVELS = {
	ok:   { text: _('OK'),   label: 'label success' },
	fail: { text: _('Fail'), label: 'label important danger' },
	warn: { text: _('Warn'), label: 'label warning' },
	skip: { text: _('Skip'), label: 'label' }
};

// Titles and descriptions of the parameters this page knows; any other the daemon
// reports is shown under its name.
const TIMING = {
	cycle:              [ _('Check interval'), _('Seconds between the end of one check and the start of the next. A hub uses this parameter only.') ],
	n_up:               [ _('Checks before a direct test'), _('Checks in a row with evidence of a direct path before steer mode tests it.') ],
	m_down:             [ _('Missed checks before the hub'), _('Checks in a row without an answer over the direct path before a peer goes back to the hub.') ],
	tunnel_timeout:     [ _('Answer timeout'), _('Seconds each check waits for its answers.') ],
	trial_window:       [ _('Direct test time'), _('Seconds a direct test waits for an answer. Must be longer than the check interval and the answer timeout together.') ],
	backoff_min:        [ _('First wait after a failure'), _('Seconds before the next direct test after a failed one, or after a fall back to the hub. The wait doubles with each failure.') ],
	backoff_max:        [ _('Longest wait after failures'), _('The wait after failures grows up to this many seconds.') ],
	backoff_reset:      [ _('Direct time that clears the wait'), _('Seconds a peer must stay on the direct path before the wait after failures starts over.') ],
	discovery_interval: [ _('Peer list refresh'), _('Seconds between fetches of the peer list from the hub.') ],
	give_up_after:      [ _('Failed tests before giving up'), _('Failed direct tests in a row on the same address after which it is given up: evidence of a direct path alone no longer tests it.') ],
	give_up_pause:      [ _('Given-up time'), _('Seconds an address stays given up before one more direct test may try it.') ]
};

function lookup(table, key) {
	return Object.prototype.hasOwnProperty.call(table, key) ? table[key] : null;
}

function alertBox(kind, children) {
	return E('div', { 'class': 'alert-message ' + kind }, children);
}

function modeWord(mode) {
	return (mode === 'steer') ? _('steer') : (mode === 'observe') ? _('observe') : mode;
}

function peerCount(n, one, many) {
	return N_(n, one, many).format(n);
}

// The words of the first phrase whose pattern matches, as pieces for E(); the text as
// it is when none does.
function inWords(phrases, text) {
	for (const [ re, words ] of phrases) {
		const m = re.exec(text);
		if (m)
			return words(m);
	}

	return [ text ];
}

function flowText(flow) {
	return inWords([
		[ /^ICMP echo-request \(tunnel probe\)$/, () => [ _('the tunnel probe (ICMP echo request)') ] ],
		[ /^ICMPv6 echo-request \(tunnel probe\)$/, () => [ _('the tunnel probe (ICMPv6 echo request)') ] ],
		[ /^ICMPv6 echo-request \(underlay probe\)$/, () => [ _('the underlay probe (ICMPv6 echo request)') ] ],
		[ /^UDP port (\d+) \(relayed WireGuard\)$/, (m) => wgpathd.fill(_('relayed WireGuard packets (UDP port %s)'), m[1]) ],
		[ /^UDP \(relayed WireGuard\)$/, () => [ _('relayed WireGuard packets (UDP)') ] ],
		[ /^TCP port (\d+) \(peer list\)$/, (m) => wgpathd.fill(_('peer list requests (TCP port %s)'), m[1]) ]
	], flow);
}

function sourceText(source) {
	return inWords([
		[ /^(\S+) \(zone (\S+)\)$/, (m) => wgpathd.fill(_('%s (zone %s)'), m[1], m[2]) ],
		[ /^(\S+) \(no zone\)$/, (m) => wgpathd.fill(_('%s (in no zone)'), m[1]) ],
		[ /^zone (\S+)$/, (m) => wgpathd.fill(_('the %s zone'), m[1]) ]
	], source);
}

function unconfirmedText(reason) {
	return inWords([
		[ /^a rule or zone option this check does not follow applies$/, () =>
			[ _('a rule or zone option that the check does not follow applies to it') ] ],
		[ /^the firewall has custom nftables rules$/, () => [ _('the firewall has custom nftables rules, which the check does not read') ] ],
		[ /^a zone may take it by device or subnet$/, () => [ _('a zone may take it by device or subnet') ] ],
		[ /^zone (\S+) is not for IPv(\d)$/, (m) => wgpathd.fill(_('zone %s is not for IPv%s'), m[1], m[2]) ],
		[ /^(\S+) has no listen_port$/, (m) => wgpathd.fill(_('%s has no listen port, so WireGuard picks one at random'), m[1]) ],
		[ /^no such zone$/, () => [ _('there is no such zone') ] ]
	], reason);
}

// A check message in plain words, as pieces for E(); `titleOf` names an option by its
// field. A message this page does not know is shown as it is.
function findingText(message, titleOf) {
	return inWords([
		[ /^config: spoke, mode (\S+), (\d+) steered peers?, (\d+) not steered$/, (m) =>
			wgpathd.fill(_('Spoke in %s mode: %s, %s'), modeWord(m[1]),
				peerCount(+m[2], '%d peer steered', '%d peers steered'),
				peerCount(+m[3], '%d peer not steered', '%d peers not steered')) ],
		[ /^config: hub, reads (\S+), serves (\S+)$/, (m) =>
			wgpathd.fill(_('Hub: publishes the peers of %s on %s'), m[1], m[2]) ],
		[ /^config: unknown mode .(.*). runs as observe$/, (m) =>
			wgpathd.fill(_('Unknown mode %s: wgpathd runs in observe mode'), m[1]) ],
		[ /^config: discovery host (\S+) is a name, not an address: every fetch waits for DNS$/, (m) =>
			wgpathd.fill(_('The peer list URL names the hub %s instead of giving its address: every fetch waits for a DNS lookup'), m[1]) ],
		[ /^config: discovery host (\S+): route lookup failed: (.*)$/, (m) =>
			wgpathd.fill(_('The route to the hub at %s could not be looked up: %s'), m[1], m[2]) ],
		[ /^config: discovery host (\S+) routes via (\S+), not (\S+)$/, (m) =>
			wgpathd.fill(_('The hub at %s is reached through %s, not through the hub interface %s'), m[1], m[2], m[3]) ],
		[ /^service disabled \(option enabled .*\): it will not start$/, () =>
			[ _('The service is not enabled: it will not start') ] ],
		[ /^config: serve_addr (\S+) is no address of a WireGuard interface in \/etc\/config\/network$/, (m) =>
			wgpathd.fill(_('%s is not an address of a WireGuard interface: spokes should reach the peer list through the hub tunnel only'), m[1]) ],
		[ /^config: network section (\S+): .* left over from an earlier version, ignored; .*$/, (m) =>
			wgpathd.fill(_('Peer %s still has settings in the network configuration from an earlier version, which are ignored: run service wgpathd migrate on the router, or remove them'), m[1]) ],
		[ /^config: option role must be /, () =>
			[ _('Choose a role') ] ],
		[ /^config: missing option (\S+)$/, (m) =>
			wgpathd.fill(_('%s is required'), titleOf(m[1])) ],
		[ /^config: option (\S+) (.*)$/, (m) =>
			[ titleOf(m[1]), ': ', m[2] ] ],
		[ /^config: no interface (\S+) in \/etc\/config\/network$/, (m) =>
			wgpathd.fill(_('There is no interface %s'), m[1]) ],
		[ /^(\S+): up, (\d+) peers?$/, (m) =>
			wgpathd.fill(_('%s is up with %s'), m[1], peerCount(+m[2], '%d peer', '%d peers')) ],
		[ /^peer (\S+): relay (\S+) via (\S+), probes (\S+)$/, (m) =>
			wgpathd.fill(_('%s: relays through %s over %s, tests %s'), m[1], m[2], m[3], m[4]) ],
		[ /^peer (\S+): relay routes into (\S+)$/, (m) =>
			wgpathd.fill(_('%s: the route to its relay endpoint goes through %s itself, so relaying would loop. Use its address on the hub tunnel.'), m[1], m[2]) ],
		[ /^peer (\S+): relay route lookup failed: (.*) \(retried every cycle\)$/, (m) =>
			wgpathd.fill(_('%s: the route to its relay endpoint could not be looked up, tried again every check: %s'), m[1], m[2]) ],
		[ /^peer (\S+): not in (\S+) yet, skipped until it appears$/, (m) =>
			wgpathd.fill(_('%s: not in %s yet, skipped until it appears'), m[1], m[2]) ],
		[ /^peer (\S+): not steered \((.*)\)$/, (m) =>
			wgpathd.fill(_('%s: not steered. %s'), m[1], wgpathd.unmanagedText(m[2])) ],
		[ /^peer settings for (\S+): no such peer in (\S+), ignored$/, (m) =>
			wgpathd.fill(_('The settings for the key %s match no peer of %s and are ignored'), m[1], m[2]) ],
		[ /^peer settings without a public_key: ignored$/, () =>
			[ _('Peer settings without a public key are ignored') ] ],
		[ /^firewall: (.+) from (.+): accepted$/, (m) =>
			wgpathd.fill(_('The firewall accepts %s from %s'), flowText(m[1]), sourceText(m[2])) ],
		[ /^firewall: (.+) from (\S+) \(no zone\): no rule accepts it; put \S+ in a firewall zone$/, (m) =>
			wgpathd.fill(_('%s is in no firewall zone, so no rule accepts %s from it: add it to a zone'), m[2], flowText(m[1])) ],
		[ /^firewall: (.+) from zone wan: no rule accepts it: restore OpenWrt's default rule Allow-ICMPv6-Input$/, (m) =>
			wgpathd.fill(_("No firewall rule accepts %s from the wan zone: restore OpenWrt's default rule Allow-ICMPv6-Input"), flowText(m[1])) ],
		[ /^firewall: (.+) from (.+): no rule accepts it$/, (m) =>
			wgpathd.fill(_('No firewall rule accepts %s from %s'), flowText(m[1]), sourceText(m[2])) ],
		[ /^firewall: (.+) from (.+): a rule rejects it before any accepts it$/, (m) =>
			wgpathd.fill(_('A firewall rule rejects %s from %s before any rule accepts it: add the rule below ahead of it'),
				flowText(m[1]), sourceText(m[2])) ],
		[ /^firewall: (.+) from (.+): could not confirm, (.*)$/, (m) =>
			wgpathd.fill(_('Could not confirm that the firewall accepts %s from %s: %s'), flowText(m[1]), sourceText(m[2]),
				unconfirmedText(m[3])) ],
		[ /^firewall: no \/etc\/config\/firewall, not checked$/, () =>
			[ _('There is no firewall configuration: the firewall rules were not checked') ] ]
	], message);
}

// The rule a firewall finding asks for, as the check gives it: uci commands and a section
// of /etc/config/firewall, each shown as text.
function fixBlock(fix) {
	if (!L.isObject(fix) || typeof(fix.uci) !== 'string' || typeof(fix.config) !== 'string')
		return [];

	return [
		E('p', {}, [
			_('Add it under'), ' ', E('a', { 'href': L.url('admin/network/firewall/rules') }, [ _('Network → Firewall → Traffic Rules') ]),
			', ', _('or on the router with:')
		]),
		E('pre', {}, [ fix.uci ]),
		E('p', {}, [ _('It is this section of /etc/config/firewall:') ]),
		E('pre', {}, [ fix.config ])
	];
}

function asText(pieces) {
	return pieces.map((p) => dom.elem(p) ? p.textContent : String(p)).join('');
}

function withinBounds(value, p) {
	if (value === '')
		return true;

	const number = p.whole ? /^[0-9]+$/ : /^[0-9]+(\.[0-9]+)?$/;
	if (number.test(value) && +value >= p.min && +value <= p.max)
		return true;

	return p.whole
		? _('Expecting: a whole number from %h to %h').format(p.min, p.max)
		: _('Expecting: a number from %h to %h').format(p.min, p.max);
}

// The peers of the mesh interface, one row each, with the relay endpoint and tunnel
// address of the `peer` section of their public key. A row cleared of both has no
// section; every section of a key a row changes is changed alike. A peer with a fixed
// endpoint and no section, such as the hub, shows no fields until it is chosen to be
// steered: another spoke may have one too, as a roamer gives an anchor its stable address.
const PeerTable = form.Value.extend({
	__name__: 'CBI.WgpathdPeers',

	__init__(...args) {
		this.super('__init__', args);
		this.iface = null;
		this.peers = [];
		this.fields = {};
		this.marks = {};
	},

	load(section_id) {
		const saved = {};

		for (const s of uci.sections('wgpathd', 'peer'))
			if (typeof(s.public_key) === 'string' && !lookup(saved, s.public_key))
				saved[s.public_key] = { relay: s.relay ?? '', tunnel: s.tunnel ?? '' };

		return saved;
	},

	renderWidget(section_id, option_index, cfgvalue) {
		this.saved = cfgvalue ?? {};
		this.container = E('div', { 'id': this.cbid(section_id) }, [ this.renderTable() ]);
		return this.container;
	},

	// Rows start from the saved settings: what was typed for another interface's peers is dropped.
	setPeers(iface, peers) {
		this.iface = iface;
		this.peers = peers;

		if (this.container)
			dom.content(this.container, [ this.renderTable() ]);
	},

	renderTable() {
		const headers = [ _('Peer'), _('Public key'), _('Relay endpoint'), _('Tunnel address'), _('Steered') ];
		const rows = this.peers.map((peer, i) => this.renderRow(peer, i, headers));

		this.fields = {};
		rows.filter((row) => row.key != null).forEach((row) => this.fields[row.key] = row);

		const body = rows.length ? rows.map((row) => row.node) : [
			E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': String(headers.length) }, [
					E('em', {}, this.iface
						? wgpathd.fill(_('%s has no peers. Add them to the WireGuard interface under Network → Interfaces.'), this.iface)
						: [ _('Choose the mesh interface on the General tab.') ])
				])
			])
		];

		const fixed = this.peers.some((peer) => peer.fixed_endpoint === true);

		return E([], [
			this.iface ? E('p', {}, wgpathd.fill(_('The peers of %s.'), this.iface)) : E([], []),
			fixed ? E('p', {}, [
				_('Peers with a fixed endpoint in their WireGuard settings, such as the hub, keep that endpoint and are not steered.'), ' ',
				_('Steer one only if it is another spoke: wgpathd then sets its endpoint instead.')
			]) : E([], []),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, headers.map((h) => E('th', { 'class': 'th' }, [ h ])))
			].concat(body))
		]);
	},

	renderRow(peer, i, headers) {
		const key = peer.public_key;
		const usable = /^[A-Za-z0-9+\/]{43}=$/.test(key ?? '');
		const saved = lookup(this.saved, key) ?? { relay: '', tunnel: '' };
		const steered = E('span', {}, []);
		// The datatype check leaves a part of the value where the validator's argument
		// should be, so the mark is held against the field's value.
		const field = (name, placeholder, datatype, title) => {
			const widget = new ui.Textfield(saved[name], {
				optional: true,
				placeholder: placeholder,
				datatype: datatype,
				disabled: !usable || this.map.readonly,
				validate: () => this.checkMark(key, name, widget.getValue())
			});
			const input = widget.render().querySelector('input');

			input.setAttribute('aria-label', title);
			input.addEventListener('input', () => this.showSteered(row));
			return widget;
		};
		const row = { key: usable ? key : null, peer: peer, steered: steered, fixed: peer.fixed_endpoint === true };

		row.relay = field('relay', _('address:port'), 'ipaddrport(1)', headers[2]);
		row.tunnel = field('tunnel', _('address'), 'ipaddr(1)', headers[3]);
		this.showSteered(row);

		const name = [ E('strong', {}, [ peer.section ]) ];
		if (peer.description)
			name.push(E('br'), E('small', {}, [ peer.description ]));

		const settings = [
			E('td', { 'class': 'td', 'data-title': headers[2] }, [ row.relay.node ]),
			E('td', { 'class': 'td', 'data-title': headers[3] }, [ row.tunnel.node ])
		];

		row.node = E('tr', { 'class': 'tr cbi-rowstyle-' + (1 + i % 2), 'data-key': usable ? key : null }, [
			E('td', { 'class': 'td', 'data-title': headers[0] }, name),
			E('td', { 'class': 'td', 'data-title': headers[1] }, usable
				? [ E('code', {}, [ key.substring(0, 8) + '…' ]) ]
				: [ E('em', {}, [ _('No valid public key') ]) ]),
			...((row.fixed && !lookup(this.saved, key)) ? [ this.renderFixed(row, settings) ] : settings),
			E('td', { 'class': 'td', 'data-title': headers[4] }, [ steered ])
		]);

		return row;
	},

	renderFixed(row, settings) {
		const cell = E('td', { 'class': 'td', 'colspan': '2', 'data-title': _('Endpoint') }, [
			E('em', {}, [ _('Fixed endpoint') ]), ' ',
			E('button', {
				'class': 'cbi-button cbi-button-neutral',
				'type': 'button',
				'disabled': (row.key == null || this.map.readonly) ? '' : null,
				'click': () => {
					cell.replaceWith(...settings);
					settings[0].querySelector('input').focus();
				}
			}, [ _('Steer this peer') ])
		]);

		return cell;
	},

	showSteered(row) {
		const set = row.relay.getValue() !== '' && row.tunnel.getValue() !== '';
		const words = row.fixed
			? (set ? _('Yes, in place of its fixed endpoint') : _('No, it keeps its fixed endpoint'))
			: (set ? _('Yes') : _('No'));

		dom.content(row.steered, [ words ]);
	},

	// A finding marks a field until its value changes.
	checkMark(key, name, value) {
		const mark = lookup(this.marks, `${key} ${name}`);
		return (mark && mark.value === value) ? mark.message : true;
	},

	mark(key, name, message) {
		const row = lookup(this.fields, key);
		if (!row || !row[name])
			return false;

		this.marks[`${key} ${name}`] = { value: row[name].getValue(), message: message };
		row[name].triggerValidation();
		return true;
	},

	clearMarks() {
		this.marks = {};
		this.triggerValidation();
	},

	// The rows of peers with a valid key: the others cannot be given settings.
	rows() {
		return Object.values(this.fields);
	},

	formvalue(section_id) {
		const out = {};

		for (const row of this.rows())
			out[row.key] = { relay: row.relay.getValue(), tunnel: row.tunnel.getValue() };

		return out;
	},

	isValid(section_id) {
		return this.rows().every((row) => row.relay.isValid() && row.tunnel.isValid());
	},

	getValidationError(section_id) {
		for (const row of this.rows())
			for (const name of [ 'relay', 'tunnel' ])
				if (!row[name].isValid())
					return `${row.peer.section}: ${row[name].getValidationError()}`;

		return '';
	},

	triggerValidation(section_id) {
		let changed = false;

		for (const row of this.rows())
			for (const name of [ 'relay', 'tunnel' ])
				changed = row[name].triggerValidation() || changed;

		return changed;
	},

	// Kept while another role hides the tab: a hub ignores them.
	parse(section_id) {
		if (!this.isActive(section_id))
			return Promise.resolve();

		if (!this.isValid(section_id))
			return Promise.reject(new TypeError(`${_('A peer setting is not valid:')} ${this.getValidationError(section_id)}`));

		const now = this.formvalue(section_id);

		for (const key in now) {
			const was = lookup(this.saved, key) ?? { relay: '', tunnel: '' };
			if (was.relay !== now[key].relay || was.tunnel !== now[key].tunnel)
				this.writePeer(key, now[key]);
		}

		return Promise.resolve();
	},

	writePeer(key, values) {
		const sections = uci.sections('wgpathd', 'peer').filter((s) => s.public_key === key).map((s) => s['.name']);

		if (values.relay === '' && values.tunnel === '') {
			sections.forEach((sid) => uci.remove('wgpathd', sid));
			return;
		}

		if (!sections.length) {
			const sid = uci.add('wgpathd', 'peer');
			uci.set('wgpathd', sid, 'public_key', key);
			sections.push(sid);
		}

		for (const sid of sections)
			for (const name of [ 'relay', 'tunnel' ])
				if (values[name] === '')
					uci.unset('wgpathd', sid, name);
				else
					uci.set('wgpathd', sid, name, values[name]);
	}
});

return view.extend({
	// The peers of the mesh interface in the committed config: those of the committed
	// role's interface if it is that one, else asked for.
	load() {
		return Promise.all([
			wgpathd.status(),
			wgpathd.meshPeers(),
			L.resolveDefault(callSchema(), null),
			uci.load('wgpathd')
		]).then(([ status, mesh, schema ]) => {
			const iface = uci.get('wgpathd', 'main', 'mesh_iface');

			if (!mesh?.interfaces?.includes(iface))
				return [ status, mesh, schema, null, [] ];

			if (mesh.iface === iface)
				return [ status, mesh, schema, iface, mesh.peers ];

			return wgpathd.meshPeers(iface).then((own) => [ status, mesh, schema, iface, own?.peers ?? [] ]);
		});
	},

	render([ status, mesh, schema, iface, peers ]) {
		const m = new form.Map('wgpathd');
		const s = m.section(form.NamedSection, 'main', 'wgpathd');

		this.map = m;
		this.options = {};
		this.tabs = {};
		this.titles = {};
		this.marks = {};

		s.tab('general', _('General'));
		s.tab('peers', _('Peers'), _('A peer is steered once it has both a relay endpoint and a tunnel address; clearing both stops steering it. They are kept in /etc/config/wgpathd, by public key.'));
		s.tab('timing', _('Timing'), _('Leave a field empty to use the default it shows.'));

		this.renderGeneral(s, mesh?.interfaces ?? []);
		this.renderPeers(s, iface, peers);
		this.renderTiming(s, schema);

		this.panel = E('div', {}, []);

		return m.render().then((node) => E([], [
			E('h2', { 'name': 'content' }, [ _('Mesh paths') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('Which peers wgpathd steers, and how.'), ' ', _('What each peer is doing right now is under'), ' ',
				E('a', { 'href': L.url('admin/status/wgpathd') }, [ _('Status → Mesh paths') ]), '.'
			]),
			E([], this.alerts(status, mesh, schema)),
			this.panel,
			node
		]));
	},

	alerts(status, mesh, schema) {
		const out = [];

		if (!wgpathd.isRunning(status))
			out.push(alertBox('warning', [
				_('The wgpathd service is not running.'), ' ', _('Its settings can still be changed and checked here.')
			]));

		if (!L.isObject(mesh) || !Array.isArray(mesh.interfaces))
			out.push(alertBox('warning', [ _('The WireGuard interfaces of this router could not be read.') ]));
		else if (!mesh.interfaces.length)
			out.push(alertBox('warning', [
				_('This router has no WireGuard interface yet.'), ' ', _('Set up the mesh and hub interfaces under'), ' ',
				E('a', { 'href': L.url('admin/network/network') }, [ _('Network → Interfaces') ]), ' ', _('first.')
			]));

		if (!L.isObject(schema) || !Array.isArray(schema.parameters))
			out.push(alertBox('warning', [ _('The timing parameters could not be read.') ]));

		return out;
	},

	// An option of main that the check may name, on its tab.
	option(s, tab, type, name, title, description) {
		const o = s.taboption(tab, type, name, title, description);

		this.options[name] = o;
		this.tabs[name] = tab;
		this.titles[name] = title;
		this.guard(o);
		return o;
	},

	// A failed finding marks its field until the value changes; `own` validates first.
	guard(o, own) {
		o.validate = (section_id, value) => {
			const mark = lookup(this.marks, o.option);
			if (mark && mark.value === o.formvalue(section_id))
				return mark.message;
			return own ? own(value) : true;
		};
	},

	// The WireGuard interfaces, and the committed value when it is none of them. Unset,
	// it asks for a choice rather than showing the first interface as chosen.
	interfaceOption(s, name, title, description, interfaces) {
		const o = this.option(s, 'general', form.ListValue, name, title, description);
		const current = uci.get('wgpathd', 'main', name);

		o.optional = true;
		interfaces.forEach((iface) => o.value(iface));
		if (current && !interfaces.includes(current))
			o.value(current);

		return o;
	},

	renderGeneral(s, interfaces) {
		let o = this.option(s, 'general', form.Flag, 'enabled', _('Enable'));
		// The service takes an unset option as enabled.
		o.default = '1';
		o.rmempty = false;

		o = this.option(s, 'general', form.ListValue, 'role', _('Role'));
		o.value('spoke', _('Spoke: steers its own peers'));
		o.value('hub', _("Hub: publishes the spokes' addresses"));
		o.rmempty = false;

		o = this.option(s, 'general', form.ListValue, 'mode', _('Mode'),
			_('Start in observe mode, and switch to steer once the Status page shows what wgpathd would do.'));
		o.value('observe', _('Observe: watches the paths but never switches them'));
		o.value('steer', _('Steer: switches paths automatically'));
		o.default = 'observe';
		o.depends('role', 'spoke');

		o = this.interfaceOption(s, 'mesh_iface', _('Mesh interface'),
			_('The WireGuard interface whose peers wgpathd steers.'), interfaces);
		o.depends('role', 'spoke');
		o.onchange = (ev, section_id, value) => this.showPeersOf(value);

		o = this.interfaceOption(s, 'hub_iface', _('Hub interface'),
			_('The WireGuard interface to the hub: relayed traffic and the peer list go through it.'), interfaces);
		o.depends('role', 'spoke');

		o = this.option(s, 'general', form.Value, 'discovery', _('Peer list URL'),
			_("Where the hub publishes the spokes' direct addresses: its address on the hub interface, its port, and /peers."));
		o.placeholder = 'http://10.10.0.1:7780/peers';
		o.depends('role', 'spoke');
		this.guard(o, (value) => (value === '' || /^http:\/\/[^\s\/]+\/\S*$/.test(value))
			? true : _('Expecting: a URL of the form http://address:port/path'));

		o = this.interfaceOption(s, 'read_iface', _('Mesh interface'),
			_('The WireGuard interface whose peers the hub publishes.'), interfaces);
		o.depends('role', 'hub');

		o = this.option(s, 'general', form.Value, 'serve_addr', _('Publish on'),
			_("The hub's address on the spokes' tunnel, so that only the spokes can reach the list."));
		o.datatype = 'ipaddr(1)';
		o.placeholder = '10.10.0.1';
		o.depends('role', 'hub');

		o = this.option(s, 'general', form.Value, 'serve_port', _('Port'));
		o.datatype = 'port';
		o.placeholder = '7780';
		o.depends('role', 'hub');
	},

	renderPeers(s, iface, peers) {
		const o = s.taboption('peers', PeerTable, '_peers', '');

		o.setPeers(iface, peers);
		o.depends('role', 'spoke');
		this.peerTable = o;
	},

	showPeersOf(iface) {
		if (!iface)
			return this.peerTable.setPeers(null, []);

		return wgpathd.meshPeers(iface).then((mesh) => this.peerTable.setPeers(iface, mesh?.peers ?? []));
	},

	// A parameter name is an identifier, so it holds no markup to be rendered as a title.
	renderTiming(s, schema) {
		for (const p of (schema?.parameters ?? [])) {
			if (!/^[a-z][a-z0-9_]*$/.test(p.name))
				continue;

			const words = lookup(TIMING, p.name);
			const o = this.option(s, 'timing', form.Value, p.name, words ? words[0] : p.name, words ? words[1] : null);

			o.placeholder = String(p.default);
			this.guard(o, (value) => withinBounds(value, p));
		}
	},

	titleOf(name) {
		return lookup(this.titles, name) ?? name;
	},

	// The form's values as saving them would leave main and the peers: an empty or
	// hidden option is removed.
	candidate() {
		const main = {};

		for (const name in this.options) {
			const o = this.options[name];
			const value = o.isActive('main') ? o.formvalue('main') : null;
			main[name] = (value == null) ? '' : String(value);
		}

		const candidate = { main: main };
		if (this.peerTable.isActive('main'))
			candidate.peers = this.peerTable.formvalue('main');

		return candidate;
	},

	check() {
		return callCheck(this.candidate()).then((res) => {
			if (!L.isObject(res) || !Array.isArray(res.findings)) {
				this.showProblem([ _('The configuration could not be checked:'), ' ', String(res?.message ?? res?.error ?? '') ]);
				return null;
			}

			this.showFindings(res.findings);
			this.markFindings(res.findings);
			return res;
		}, (err) => {
			this.showProblem([ _('The configuration could not be checked:'), ' ', String(err?.message ?? err) ]);
			return null;
		});
	},

	showProblem(children) {
		this.clearMarks();
		dom.content(this.panel, alertBox('error', children));
	},

	showFindings(findings, refused) {
		const rows = findings.map((f) => {
			const level = lookup(LEVELS, f.level);

			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'width': '10%' }, [
					E('span', { 'class': level ? level.label : 'label' }, [ level ? level.text : String(f.level) ])
				]),
				E('td', { 'class': 'td' }, findingText(String(f.message), (name) => this.titleOf(name)).concat(fixBlock(f.fix)))
			]);
		});

		dom.content(this.panel, E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('Configuration check') ]),
			refused ? alertBox('error', [
				_('Nothing was saved or applied: the check found problems, which wgpathd would refuse or leave unsteered.'), ' ',
				_('Fix the fields it marks, then try again.')
			]) : E([], []),
			E('table', { 'class': 'table' }, rows)
		]));
	},

	clearMarks() {
		this.marks = {};
		for (const name in this.options)
			if (this.options[name].isActive('main'))
				this.options[name].triggerValidation('main');
		this.peerTable.clearMarks();
	},

	// The interface option set to a missing interface, since that finding names no option.
	interfaceOptionOf(f) {
		const m = /^config: no interface (\S+) in /.exec(String(f.message));
		const names = [ 'mesh_iface', 'hub_iface', 'read_iface' ];

		return m ? names.find((name) => this.options[name].isActive('main') && this.options[name].formvalue('main') === m[1]) : null;
	},

	// Marks the field a failed finding is about, if it has one; returns the tab to show.
	mark(f, message) {
		if (f.subject === 'peer')
			return (this.peerTable.mark(f.public_key, f.option, message) || this.peerTable.isActive('main')) ? 'peers' : null;

		const name = f.option ?? this.interfaceOptionOf(f);
		const o = name ? lookup(this.options, name) : null;
		if (!o || !o.isActive('main'))
			return 'general';

		this.marks[name] = { value: o.formvalue('main'), message: message };
		o.triggerValidation('main');
		return lookup(this.tabs, name);
	},

	markFindings(findings) {
		let first = null;

		this.clearMarks();

		for (const f of findings)
			if (f.level === 'fail') {
				const tab = this.mark(f, asText(findingText(String(f.message), (name) => this.titleOf(name))));
				first ??= tab;
			}

		ui.tabs.updateTabs(null, this.map.root);

		if (first)
			this.map.root.querySelector(`.cbi-tabmenu > li[data-tab="${first}"] > a`)?.click();
	},

	addFooter() {
		const footer = this.super('addFooter', []);
		const actions = footer.querySelector('.cbi-page-actions');

		if (actions)
			actions.prepend(E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, 'handleCheck')
			}, [ _('Check configuration') ]), ' ');

		return footer;
	},

	handleCheck(ev) {
		return this.check();
	},

	// The daemon would refuse an invalid configuration, and leave a peer with bad
	// settings unsteered: neither is applied.
	handleSaveApply(ev, mode) {
		return this.check().then((res) => {
			if (res == null)
				return;

			if (!res.ok)
				return this.showFindings(res.findings, true);

			return this.super('handleSaveApply', [ ev, mode ]);
		});
	},

	handleReset(ev) {
		dom.content(this.panel, []);
		this.marks = {};
		return this.super('handleReset', [ ev ]);
	}
});
