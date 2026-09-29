import { describe, it, assert, contains } from 'utest';
import * as h from 'lib.helpers';
import * as candidate from 'wgpathd.candidate';
import * as config from 'wgpathd.config';

const SPOKE_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const HUB  = 'W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=';

const MAIN = { '.type': 'wgpathd', role: 'spoke', mesh_iface: 'wg_mesh', hub_iface: 'wg_hub',
	discovery: 'http://10.10.0.1:7780/peers', mode: 'observe', cycle: '2' };

const SPOKE_B_SETTINGS = { '.type': 'peer', public_key: SPOKE_B, relay: '10.10.0.12:51820', tunnel: '10.20.0.12' };

const NETWORK = {
	wg_mesh: { '.type': 'interface', proto: 'wireguard' },
	wg_hub:  { '.type': 'interface', proto: 'wireguard' },
	spoke_b: { '.type': 'wireguard_wg_mesh', public_key: SPOKE_B },
	hub: { '.type': 'wireguard_wg_mesh', public_key: HUB },
};

function cursor(data) {
	return h.uci(data ?? { wgpathd: { main: MAIN, cfg01a2b3: SPOKE_B_SETTINGS }, network: NETWORK }).cursor();
}

function view(cand, data) {
	let res = candidate.overlay(cursor(data), cand);
	assert.match(true, res.ok, res.details);
	return res.data;
}

// The `peer` sections the view shows, by public key.
function settings(v) {
	let out = {};
	v.foreach('wgpathd', 'peer', (s) => { out[s.public_key] = { relay: s.relay, tunnel: s.tunnel }; });
	return out;
}

describe('candidate: main', () => {
	it('replaces the options it gives and keeps every other committed option', () => {
		let v = view({ main: { mode: 'steer', cycle: '1' } });
		assert.match({ ...MAIN, '.name': 'main', mode: 'steer', cycle: '1' }, v.get_all('wgpathd', 'main'));
		assert.match([ 'steer', 'wg_mesh' ], [ v.get('wgpathd', 'main', 'mode'), v.get('wgpathd', 'main', 'mesh_iface') ]);
	});

	it('removes an option given as an empty string', () => {
		let v = view({ main: { cycle: '', discovery: '' } });
		let main = v.get_all('wgpathd', 'main');
		assert.match([ false, false, 'observe' ], [ exists(main, 'cycle'), exists(main, 'discovery'), main.mode ]);
		assert.match(null, v.get('wgpathd', 'main', 'cycle'));
	});

	it('takes a number as the text UCI would hold', () => {
		let v = view({ main: { backoff_min: 45, cycle: 0.5 } });
		assert.match([ '45', '0.5' ], [ v.get('wgpathd', 'main', 'backoff_min'), v.get('wgpathd', 'main', 'cycle') ]);
	});

	it('stands in for a main section the committed config lacks', () => {
		let v = view({ main: { role: 'hub' } }, { wgpathd: {}, network: NETWORK });
		assert.match({ '.name': 'main', '.type': 'wgpathd', role: 'hub' }, v.get_all('wgpathd', 'main'));
		assert.match('wgpathd', v.get('wgpathd', 'main'));
	});

	it('leaves the committed config alone', () => {
		let uci = cursor();
		candidate.overlay(uci, { main: { mode: 'steer' }, peers: { [SPOKE_B]: { relay: '' } } });
		assert.match('observe', uci.get('wgpathd', 'main', 'mode'));
		assert.match('10.10.0.12:51820', uci.get('wgpathd', 'cfg01a2b3', 'relay'));
	});
});

describe('candidate: peers', () => {
	it('adds the settings of a peer that has none', () => {
		let v = view({ peers: { [HUB]: { relay: '10.10.0.1:51820', tunnel: '10.20.0.1' } } });
		assert.match({ [SPOKE_B]: { relay: '10.10.0.12:51820', tunnel: '10.20.0.12' },
			[HUB]: { relay: '10.10.0.1:51820', tunnel: '10.20.0.1' } }, settings(v));
	});

	it('lays the options it gives over the committed settings, keeping the others', () => {
		let v = view({ peers: { [SPOKE_B]: { tunnel: '10.20.0.99' } } });
		assert.match({ [SPOKE_B]: { relay: '10.10.0.12:51820', tunnel: '10.20.0.99' } }, settings(v));
	});

	it('removes an option given as an empty string', () => {
		let v = view({ peers: { [SPOKE_B]: { tunnel: '' } } });
		assert.match({ [SPOKE_B]: { relay: '10.10.0.12:51820', tunnel: null } }, settings(v));
	});

	it('drops the settings of a peer left with neither option, as the form removes them', () => {
		assert.match({}, settings(view({ peers: { [SPOKE_B]: { relay: '', tunnel: '' } } })));
		assert.match({ [SPOKE_B]: { relay: '10.10.0.12:51820', tunnel: '10.20.0.12' } },
			settings(view({ peers: { [HUB]: { relay: '' } } })));
	});

	it('changes every section of a key given twice, keeping them twice', () => {
		let data = { wgpathd: { main: MAIN, a: SPOKE_B_SETTINGS, b: SPOKE_B_SETTINGS }, network: NETWORK };
		let tunnels = [];
		view({ peers: { [SPOKE_B]: { tunnel: '10.20.0.99' } } }, data).foreach('wgpathd', 'peer', (s) => push(tunnels, s.tunnel));
		assert.match([ '10.20.0.99', '10.20.0.99' ], tunnels);
	});

	it('passes every other package and section type through', () => {
		let v = view({ peers: { [SPOKE_B]: { relay: '' } } });
		let types = [];
		v.foreach('network', null, (s) => push(types, s['.type']));
		assert.match([ 'interface', 'interface', 'wireguard_wg_mesh', 'wireguard_wg_mesh' ], types);
	});
});

describe('candidate: what config.load makes of it', () => {
	it('loads the candidate as if it were committed', () => {
		let v = view({ main: { mode: 'steer' }, peers: { [HUB]: { relay: 'bad' }, [SPOKE_B]: { tunnel: '' } } });
		let res = config.load({ uci: v });
		assert.match(contains({ mode: 'steer', overrides: { cycle: 2 },
			peers: { managed: [], stale: [], unmanaged: [
				{ section: 'spoke_b', pubkey: SPOKE_B, reason: 'missing tunnel' },
				{ section: 'hub', pubkey: HUB, reason: 'invalid relay' },
			] } }), res.data);
	});

	it('fails the way a committed config would', () => {
		assert.match(contains({ ok: false, error: 'CONFIG_MISSING_OPTION', details: 'discovery' }),
			config.load({ uci: view({ main: { discovery: '' } }) }));
	});
});

describe('candidate: refused', () => {
	let cases = [
		[ 'x', 'candidate must be an object' ],
		[ { main: {}, network: {} }, "unknown part 'network'" ],
		[ { main: 'steer' }, 'main must be an object' ],
		[ { main: { '.type': 'x' } }, "main: unknown option '.type'" ],
		[ { main: { 'mode name': 'x' } }, "main: unknown option 'mode name'" ],
		[ { main: { enabled: true } }, 'main.enabled must be a string or a number' ],
		[ { main: { mode: [ 'steer' ] } }, 'main.mode must be a string or a number' ],
		[ { peers: [] }, 'peers must be an object' ],
		[ { peers: { spoke_b: { relay: '10.0.0.1:1' } } }, "peers: 'spoke_b' is not a WireGuard public key" ],
		[ { peers: { '@peer[0]': { relay: '10.0.0.1:1' } } }, "peers: '@peer[0]' is not a WireGuard public key" ],
		[ { peers: { [SPOKE_B]: { public_key: HUB } } }, `peers.${SPOKE_B}: unknown option 'public_key'` ],
		[ { peers: { [SPOKE_B]: { wgpathd_relay: '10.0.0.1:1' } } }, `peers.${SPOKE_B}: unknown option 'wgpathd_relay'` ],
		[ { peers: { [SPOKE_B]: { relay: true } } }, `peers.${SPOKE_B}.relay must be a string or a number` ],
		[ { peers: { [SPOKE_B]: 'x' } }, `peers.${SPOKE_B} must be an object` ],
	];
	for (let c in cases)
		it(`refuses ${c[1]}`, () => {
			assert.match({ ok: false, error: 'CHECK_INVALID_CANDIDATE', details: c[1] }, { ...candidate.overlay(cursor(), c[0]) });
		});
});
