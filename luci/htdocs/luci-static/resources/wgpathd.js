'use strict';
'require baseclass';
'require rpc';
'require uci';

// Shared by the wgpathd views and the Overview include: the status call and the
// words and pictures for its reply.
//
// Every string from the daemon or the config ends up in a text node: E() gets
// children as arrays only, and fill() puts data between the pieces of a translated
// template instead of formatting it into markup.

const callStatus = rpc.declare({
	object: 'wgpathd',
	method: 'status'
});

// The WireGuard interfaces and the peers of one, without their keys; served by rpcd
// whether or not the daemon runs.
const callPeers = rpc.declare({
	object: 'wgpathd.config',
	method: 'peers',
	params: [ 'iface' ]
});

const STATES = {
	DIRECT:   { text: _('Direct'),         label: 'label success', segment: 'border-top:3px solid' },
	RELAY:    { text: _('Via hub'),        label: 'label warning', segment: 'border-top:2px dashed' },
	TRIALING: { text: _('Testing direct'), label: 'label notice',  segment: 'border-top:3px dotted' }
};

const UNMANAGED = {
	'invalid public_key':        _('No valid public key'),
	'not configured':            _('No relay endpoint or tunnel address set'),
	'configured more than once': _('Its settings are given more than once'),
	'missing relay':             _('No relay endpoint set'),
	'invalid relay':             _('The relay endpoint is not valid'),
	'missing tunnel':            _('No tunnel address to check set'),
	'invalid tunnel':            _('The tunnel address is not valid')
};

// Why this router does not try the address the hub publishes for a peer.
const REFUSED = {
	'own address':    _('It is an address of this router'),
	'relay address':  _('It is the relay endpoint of this peer'),
	'tunnel address': _('It is the tunnel address of this peer')
};

const NODE_STYLE = 'display:inline-block;padding:0 .6em;border:1px solid;border-radius:1em;line-height:1.6;' +
	'white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:10em';

// The text of the filled hub node is inverted rather than coloured, so it contrasts
// with its currentColor fill in light and dark themes alike.
const HUB_STYLE = NODE_STYLE + ';background:currentColor';
const HUB_TEXT_STYLE = 'filter:invert(1)';

// A WireGuard session lapses 180 s after the last handshake (REJECT_AFTER_TIME).
const SESSION_LIFETIME = 180;

function lookup(table, key) {
	return Object.prototype.hasOwnProperty.call(table, key) ? table[key] : null;
}

function fill(template, ...args) {
	const parts = template.split('%s');
	const out = [];

	parts.forEach((part, i) => {
		if (part !== '')
			out.push(part);
		if (i < parts.length - 1)
			out.push(args[i] ?? '');
	});

	return out;
}

function duration(secs) {
	secs = Math.max(0, Math.floor(secs));

	if (secs < 60)
		return _('%d s').format(secs);

	const mins = Math.floor(secs / 60);
	if (mins < 60)
		return _('%d min').format(mins);

	const hours = Math.floor(mins / 60);
	if (hours < 24)
		return (mins % 60) ? _('%d h %d min').format(hours, mins % 60) : _('%d h').format(hours);

	const days = Math.floor(hours / 24);
	return (hours % 24) ? _('%d d %d h').format(days, hours % 24) : _('%d d').format(days);
}

function node(name) {
	return E('span', { 'style': NODE_STYLE }, [ name ]);
}

function hubNode() {
	return E('span', { 'style': HUB_STYLE }, [ E('span', { 'style': HUB_TEXT_STYLE }, [ _('hub') ]) ]);
}

function segment(state) {
	return E('span', { 'style': 'flex:1 1 1.5em;min-width:1.5em;height:0;' + lookup(STATES, state).segment });
}

return baseclass.extend({
	SESSION_LIFETIME: SESSION_LIFETIME,

	fill: fill,
	duration: duration,

	status() {
		return L.resolveDefault(callStatus(), null);
	},

	// { iface, interfaces, peers: [ { section, public_key, description? } ] } for `iface`,
	// or for the interface of the committed role when it is left out; null when unreadable.
	meshPeers(iface) {
		return L.resolveDefault(callPeers(iface), null);
	},

	// The reply, with the router's name and time zone from the system config (readable
	// through luci-base's ACL) and the names of the peers, which the hub's reply lacks.
	load() {
		return Promise.all([
			this.status(),
			L.resolveDefault(uci.load([ 'system', 'wgpathd' ]), null),
			this.meshPeers()
		]).then(([ status, , peers ]) => {
			this.named = peers?.peers ?? [];
			return status;
		});
	},

	isRunning(status) {
		return L.isObject(status);
	},

	isSpoke(status) {
		return L.isObject(status) && status.role === 'spoke' && L.isObject(status.peers);
	},

	isHub(status) {
		return L.isObject(status) && status.role === 'hub' && L.isObject(status.peers);
	},

	// Managed peers of a spoke reply, by section name.
	peers(status) {
		return Object.keys(status.peers)
			.map((key) => Object.assign({ pubkey: key }, status.peers[key]))
			.sort((a, b) => String(a.section).localeCompare(String(b.section)));
	},

	routerName() {
		return uci.get('system', '@system[0]', 'hostname') || _('This router');
	},

	// The network section of the peer whose key is `pubkey`, as the hub reply is keyed by keys.
	sectionOf(pubkey) {
		const peer = (this.named ?? []).find((p) => p.public_key === pubkey);
		return peer ? peer.section : null;
	},

	// Where the spokes fetch the hub's list, from the hub's own config.
	publishedURL() {
		const addr = uci.get('wgpathd', 'main', 'serve_addr');
		const port = uci.get('wgpathd', 'main', 'serve_port');

		if (!addr || !port)
			return null;

		return 'http://' + (addr.includes(':') ? '[' + addr + ']' : addr) + ':' + port + '/peers';
	},

	ago(now, ts) {
		return fill(_('%s ago'), duration(now - ts));
	},

	// Clock time of `ts` in the router's time zone, as the system log shows it; with the
	// date when it is not from the last day.
	clockTime(now, ts) {
		const zone = (uci.get('system', '@system[0]', 'zonename') || 'UTC').replaceAll(' ', '_');
		const opts = (now - ts < 86400) ? { timeStyle: 'medium' } : { dateStyle: 'medium', timeStyle: 'medium' };
		const date = new Date(ts * 1000);

		try {
			return new Intl.DateTimeFormat(undefined, Object.assign({ timeZone: zone }, opts)).format(date);
		}
		catch (e) {
			return new Intl.DateTimeFormat(undefined, Object.assign({ timeZone: 'UTC' }, opts)).format(date);
		}
	},

	stateText(state) {
		return lookup(STATES, state)?.text ?? _('Unknown');
	},

	stateLabel(state) {
		return E('span', { 'class': lookup(STATES, state)?.label ?? 'label' }, [ this.stateText(state) ]);
	},

	// this router ─ peer (direct), this router ┄ hub ┄ peer (relay), this router ··· peer
	// (testing direct); drawn in currentColor so it follows the theme. The state label
	// next to it says the same in words, so screen readers skip it.
	pathStrip(router, peer, state) {
		if (!lookup(STATES, state))
			return E('span', {}, []);

		const middle = (state === 'RELAY')
			? [ segment(state), hubNode(), segment(state) ]
			: [ segment(state) ];

		return E('div', {
			'class': 'wgpathd-path',
			'aria-hidden': 'true',
			'style': 'display:flex;align-items:center;gap:.3em;max-width:22em'
		}, [ node(router) ].concat(middle, [ node(peer) ]));
	},

	modeText(mode) {
		if (mode === 'steer')
			return [ _('Steer: switches paths automatically') ];
		if (mode === 'observe')
			return [ _('Observe: watches the paths but never switches them') ];
		return [ mode ];
	},

	unmanagedText(reason) {
		if (lookup(UNMANAGED, reason))
			return [ lookup(UNMANAGED, reason) ];

		let m = /^relay routes into (.*)$/.exec(reason);
		if (m)
			return fill(_('The relay endpoint is routed into %s'), m[1]);

		m = /^relay route lookup failed: (.*)$/.exec(reason);
		if (m)
			return fill(_('The route to the relay endpoint could not be looked up, tried again every check: %s'), m[1]);

		return [ reason ];
	},

	refusalText(reason) {
		if (lookup(REFUSED, reason))
			return [ lookup(REFUSED, reason) ];

		const m = /^routes into (.*)$/.exec(reason);
		if (m)
			return fill(_('It is routed into %s, so a direct path would loop into a tunnel'), m[1]);

		return [ reason ];
	},

	// Why a peer in RELAY is there, from its last change.
	fallbackText(peer, params) {
		const change = peer.last_change;

		if (!L.isObject(change))
			return [ _('It has used the hub since the service started') ];

		switch (change.reason) {
		case 'demoted':
			return [ N_(params.m_down, '%d check got no answer over the direct path',
				'%d checks in a row got no answer over the direct path').format(params.m_down) ];
		case 'trial_timeout':
			return fill(_('The direct test got no answer within %s'), duration(params.trial_window));
		case 'observe_mode':
			return [ _('The service was switched to observe mode') ];
		default:
			return [ change.reason ];
		}
	},

	// Seconds until the echo alone may test a given-up direct address again; null when
	// no address is given up, or its pause is over.
	givenUpWait(peer, now) {
		const until = peer.given_up?.until;
		return (until != null && until > now) ? until - now : null;
	},

	givenUpText(peer) {
		return N_(peer.failed_trials, 'Direct address given up after %d failed test.',
			'Direct address given up after %d failed tests in a row.').format(peer.failed_trials);
	},

	// When a peer in RELAY tries the direct path next; steer mode only.
	nextTrialText(peer, now, params) {
		const wait = this.givenUpWait(peer, now);
		if (wait != null)
			return [ this.givenUpText(peer), ' ' ].concat(fill(
				_('Tries again in %s, or as soon as the hub publishes another address or the peer reaches this router directly'),
				duration(wait)));

		if (peer.next_trial != null) {
			const wait = peer.next_trial - now;

			if (wait <= 0)
				return [ _('Any moment now') ];

			return fill(_('In %s, then waits longer after each failure, up to %s'),
				duration(wait), duration(params.backoff_max));
		}

		if (peer.ready)
			return [ _('At the next check') ];

		if (peer.candidate == null)
			return [ _('Once the hub publishes a direct address for this peer') ];

		if (peer.candidate_refused != null)
			return [ _('Once the hub publishes a direct address this router can use') ];

		return [ N_(params.n_up, 'After %d answered check over the direct address; %d so far',
			'After %d answered checks in a row over the direct address; %d so far').format(params.n_up, peer.up_streak) ];
	},

	// Whether steer mode would test the direct path now; observe mode only.
	readinessText(peer, now, params) {
		const wait = this.givenUpWait(peer, now);
		if (wait != null)
			return [ _('No.'), ' ', this.givenUpText(peer), ' ' ].concat(fill(
				_('Steer mode would test it again in %s, or as soon as the hub publishes another address or the peer reaches this router directly'),
				duration(wait)));

		if (peer.ready)
			return [ _('Yes, steer mode would test the direct path now') ];

		return [ _('Not yet: %d of %d checks answered over the direct address').format(peer.up_streak, params.n_up) ];
	},

	// A history entry in words: the state it went to and why.
	changeText(entry, params) {
		switch (entry.reason) {
		case 'trial_start':
			return [ _('Testing direct, was via hub') ];
		case 'trial_ok':
			return [ _('Direct, the test passed') ];
		case 'trial_timeout':
			return fill(_('Via hub, the direct test got no answer within %s'), duration(params.trial_window));
		case 'demoted':
			return [ N_(params.m_down, 'Via hub, was direct: %d check got no answer',
				'Via hub, was direct: %d checks in a row got no answer').format(params.m_down) ];
		case 'observe_mode':
			return [ _('Via hub, the service was switched to observe mode') ];
		case 'roam_adopted':
			return fill(_('Direct, followed the peer to %s'), entry.endpoint);
		default:
			return fill(_('%s, was %s: %s'), this.stateText(entry.to), this.stateText(entry.from), entry.reason);
		}
	},

	// One short line beside the state: how long, or what happens next.
	summaryText(peer, status) {
		const now = status.now;

		switch (peer.state) {
		case 'DIRECT':
			return fill(_('for %s'), duration(now - peer.since));
		case 'TRIALING':
			return (peer.trial_deadline != null)
				? fill(_('test ends in %s'), duration(peer.trial_deadline - now))
				: [];
		case 'RELAY': {
			if (status.mode !== 'steer')
				return peer.ready ? [ _('would test direct') ] : [];
			const wait = this.givenUpWait(peer, now);
			if (wait != null)
				return fill(_('direct given up, tries again in %s'), duration(wait));
			return (peer.next_trial != null)
				? fill(_('next direct try in %s'), duration(peer.next_trial - now))
				: [];
		}
		default:
			return [];
		}
	}
});
