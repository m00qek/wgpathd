import { describe, it, assert, contains } from 'utest';
import * as h from 'lib.helpers';
import * as candidate from 'wgpathd.candidate';
import * as config from 'wgpathd.config';

const SPOKE_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const HUB  = 'W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=';

const MAIN = { '.type': 'wgpathd', role: 'spoke', mesh_iface: 'wg_mesh', hub_iface: 'wg_hub',
	discovery: 'http://10.10.0.1:7780/peers', mode: 'observe', cycle: '2' };

const NETWORK = {
	wg_mesh: { '.type': 'interface', proto: 'wireguard' },
	wg_hub:  { '.type': 'interface', proto: 'wireguard' },
	spoke_b: { '.type': 'wireguard_wg_mesh', public_key: SPOKE_B, wgpathd_relay: '10.10.0.12:51820',
		wgpathd_tunnel: '10.20.0.12' },
	hub: { '.type': 'wireguard_wg_mesh', public_key: HUB },
};

function cursor(data) {
	return h.uci(data ?? { wgpathd: { main: MAIN }, network: NETWORK }).cursor();
}

function view(cand, data) {
	let res = candidate.overlay(cursor(data), cand);
	assert.match(true, res.ok, res.details);
	return res.data;
}

function sections(v, pkg, stype) {
	let out = {};
	v.foreach(pkg, stype, (s) => { out[s['.name']] = s; });
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
		candidate.overlay(uci, { main: { mode: 'steer' }, peers: { spoke_b: { wgpathd_relay: '' } } });
		assert.match('observe', uci.get('wgpathd', 'main', 'mode'));
		assert.match('10.10.0.12:51820', uci.get('network', 'spoke_b', 'wgpathd_relay'));
	});
});

describe('candidate: peers', () => {
	it('lays the annotations over the committed peer section, which keeps its other options', () => {
		let v = view({ peers: { hub: { wgpathd_relay: '10.10.0.1:51820', wgpathd_tunnel: '10.20.0.1' } } });
		assert.match({ '.type': 'wireguard_wg_mesh', '.name': 'hub', public_key: HUB, wgpathd_relay: '10.10.0.1:51820',
			wgpathd_tunnel: '10.20.0.1' }, sections(v, 'network', 'wireguard_wg_mesh').hub);
		assert.match('10.20.0.1', v.get('network', 'hub', 'wgpathd_tunnel'));
	});

	it('removes an annotation given as an empty string, and leaves the peers it does not name', () => {
		let v = view({ peers: { spoke_b: { wgpathd_tunnel: '' } } });
		let peers = sections(v, 'network', 'wireguard_wg_mesh');
		assert.match([ false, '10.10.0.12:51820' ], [ exists(peers.spoke_b, 'wgpathd_tunnel'), peers.spoke_b.wgpathd_relay ]);
		assert.match({ ...NETWORK.hub, '.name': 'hub' }, peers.hub);
	});

	it('passes section types through: interfaces are never candidates', () => {
		let v = view({ peers: { spoke_b: { wgpathd_relay: '' } } });
		assert.match([ 'interface', 'wireguard_wg_mesh' ], [ v.get('network', 'wg_mesh'), v.get('network', 'spoke_b') ]);
	});
});

describe('candidate: what config.load makes of it', () => {
	it('loads the candidate as if it were committed', () => {
		let v = view({ main: { mode: 'steer' }, peers: { hub: { wgpathd_relay: 'bad' }, spoke_b: { wgpathd_tunnel: '' } } });
		let res = config.load({ uci: v });
		assert.match(contains({ mode: 'steer', overrides: { cycle: 2 },
			peers: { managed: [], unmanaged: [
				{ section: 'spoke_b', pubkey: SPOKE_B, reason: 'missing wgpathd_tunnel' },
				{ section: 'hub', pubkey: HUB, reason: 'invalid wgpathd_relay' },
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
		[ { peers: { spoke_z: { wgpathd_relay: '10.0.0.1:1' } } }, "no wireguard peer section 'spoke_z' in /etc/config/network" ],
		[ { peers: { wg_mesh: { wgpathd_relay: '10.0.0.1:1' } } }, "no wireguard peer section 'wg_mesh' in /etc/config/network" ],
		[ { peers: { spoke_b: { public_key: 'x' } } }, "peers.spoke_b: unknown option 'public_key'" ],
		[ { peers: { spoke_b: 'x' } }, 'peers.spoke_b must be an object' ],
	];
	for (let c in cases)
		it(`refuses ${c[1]}`, () => {
			assert.match({ ok: false, error: 'CHECK_INVALID_CANDIDATE', details: c[1] }, { ...candidate.overlay(cursor(), c[0]) });
		});
});
