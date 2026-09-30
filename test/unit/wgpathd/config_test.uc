import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_context } from 'context';
import * as config from 'wgpathd.config';

const SPOKE_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const SPOKE_A = 'ckRTxoRCqAhiHEgHPnhfpN6nU5/F2QmMe0nJ2kt7PFc=';
const HUB  = 'W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=';

const SPOKE = { '.type': 'wgpathd', role: 'spoke', mesh_iface: 'wg_mesh', hub_iface: 'wg_hub',
	discovery: 'http://10.10.0.1:7780/peers' };
const HUB_ROLE = { '.type': 'wgpathd', role: 'hub', read_iface: 'wg_mesh', serve_addr: '10.10.0.1',
	serve_port: '7780' };

const IFACES = {
	wg_mesh: { '.type': 'interface', proto: 'wireguard' },
	wg_hub:  { '.type': 'interface', proto: 'wireguard' },
};

function mesh_peer(pubkey) {
	return { '.type': 'wireguard_wg_mesh', public_key: pubkey, allowed_ips: [ '10.12.0.0/16' ] };
}

// A `peer` section of /etc/config/wgpathd.
function settings(pubkey, relay, tunnel) {
	return { '.type': 'peer', public_key: pubkey, relay: relay, tunnel: tunnel };
}

const SPOKE_B_PEER = mesh_peer(SPOKE_B);
const SPOKE_B_SETTINGS = settings(SPOKE_B, '10.10.0.12:51820', '10.20.0.12');
const HUB_PEER  = { '.type': 'wireguard_wg_mesh', public_key: HUB, endpoint_host: '2001:db8:100::1' };

// The `peer` sections take anonymous ids, as the ones UCI gives.
function load(main, network, peers) {
	let wgpathd = { main: main };
	for (let i = 0; i < length(peers ?? []); i++)
		wgpathd[`cfg0${i}a1b2`] = peers[i];
	let res;
	with_context({ uci: { data: { wgpathd: wgpathd, network: network ?? IFACES } } }, (deps) => {
		res = config.load(deps);
	});
	return res;
}

// The loaded peers of a spoke whose mesh has the peer sections `mesh`, and its settings.
function peers_of(mesh, peers) {
	let network = { ...IFACES };
	for (let i = 0; i < length(mesh); i++)
		network[`peer${i}`] = mesh[i];
	return load(SPOKE, network, peers).data.peers;
}

describe('config: role', () => {
	it('rejects a missing or unknown role', () => {
		for (let role in [ null, '', 'relay', 'Spoke' ])
			assert.match(contains({ ok: false, error: 'CONFIG_INVALID_ROLE' }), load({ ...SPOKE, role: role }), role);
	});

	it('rejects a config without the main section', () => {
		let res;
		with_context({ uci: { data: { wgpathd: {}, network: IFACES } } }, (deps) => { res = config.load(deps); });
		assert.match(contains({ ok: false, error: 'CONFIG_INVALID_ROLE' }), res);
	});
});

describe('config: spoke', () => {
	it('loads the role file', () => {
		assert.match({ role: 'spoke', mesh_iface: 'wg_mesh', hub_iface: 'wg_hub',
			discovery: 'http://10.10.0.1:7780/peers', overrides: {}, mode: 'observe',
			peers: { managed: [], unmanaged: [], stale: [] }, leftovers: [] },
			load(SPOKE).data);
	});

	it('defaults mode to observe and honours steer', () => {
		assert.match('observe', load(SPOKE).data.mode);
		assert.match('observe', load({ ...SPOKE, mode: 'observe' }).data.mode);
		assert.match('steer', load({ ...SPOKE, mode: 'steer' }).data.mode);
	});

	it('reads any other mode as observe, keeping it to be logged', () => {
		for (let mode in [ 'Steer', 'stear', '' ]) {
			let cfg = load({ ...SPOKE, mode: mode }).data;
			assert.match([ 'observe', mode ], [ cfg.mode, cfg.invalid_mode ]);
		}
	});

	it('flags no invalid mode when mode is valid or unset', () => {
		for (let mode in [ null, 'steer', 'observe' ])
			assert.match(false, exists(load({ ...SPOKE, mode: mode }).data, 'invalid_mode'), mode);
	});

	it('requires every spoke option', () => {
		for (let opt in [ 'mesh_iface', 'hub_iface', 'discovery' ]) {
			assert.match(contains({ ok: false, error: 'CONFIG_MISSING_OPTION', details: opt }),
				load({ ...SPOKE, [opt]: null }));
			assert.match(contains({ ok: false, error: 'CONFIG_MISSING_OPTION', details: opt }),
				load({ ...SPOKE, [opt]: '' }));
		}
	});

	it('refuses when a named interface does not exist', () => {
		assert.match(contains({ ok: false, error: 'INTERFACE_MISSING', details: 'wg_mesh' }),
			load(SPOKE, { wg_hub: IFACES.wg_hub }));
		assert.match(contains({ ok: false, error: 'INTERFACE_MISSING', details: 'wg_hub' }),
			load(SPOKE, { wg_mesh: IFACES.wg_mesh }));
	});

	it('does not take a section of another type for the interface', () => {
		assert.match(contains({ ok: false, error: 'INTERFACE_MISSING' }),
			load(SPOKE, { ...IFACES, wg_hub: { '.type': 'device' } }));
	});
});

// UCI's extended syntax: `@interface[0]` is the first section of type interface.
describe('config: interface names', () => {
	const NOT_NAMES = [ '@interface[0]', '@interface[-1]', 'wg_mesh.proto', '../network', 'wg mesh', 'wg-mesh', "wg'mesh", 'wg_mesh\n' ];

	function load_recording(main) {
		let looked_up = [];
		let uci = {
			get_all: () => main,
			get: function(pkg, section) {
				push(looked_up, section);
				return 'interface';
			},
			foreach: () => null,
		};
		return { res: config.load({ uci: uci }), looked_up: looked_up };
	}

	it('refuses an interface option that is not a plain name, before it reaches uci', () => {
		for (let opt in [ 'mesh_iface', 'hub_iface' ])
			for (let value in NOT_NAMES) {
				let l = load_recording({ ...SPOKE, [opt]: value });
				assert.match(contains({ ok: false, error: 'CONFIG_INVALID_OPTION',
					details: `${opt} must be an interface name of letters, digits and _` }), l.res, value);
				assert.match([], l.looked_up, value);
			}
		for (let value in NOT_NAMES)
			assert.match(contains({ ok: false, error: 'CONFIG_INVALID_OPTION',
				details: 'read_iface must be an interface name of letters, digits and _' }),
				load_recording({ ...HUB_ROLE, read_iface: value }).res, value);
	});

	it('takes the names UCI gives, those of anonymous sections included', () => {
		for (let name in [ 'wg_mesh', 'WG0', 'cfg09cdcd', '0' ])
			assert.match(contains({ ok: true }), load_recording({ ...SPOKE, mesh_iface: name }).res, name);
	});

	it('keeps steering the peers of anonymous sections, by their id', () => {
		let res = load(SPOKE, { ...IFACES, cfg09cdcd: SPOKE_B_PEER }, [ SPOKE_B_SETTINGS ]);
		assert.match([ 'cfg09cdcd' ], map(res.data.peers.managed, (p) => p.section));
	});
});

describe('config: discovery url', () => {
	it('takes an http url to an address or a name, credentials included', () => {
		for (let url in [ 'http://10.10.0.1:7780/peers', 'http://[fd00::1]:7780/peers', 'http://hub.example.org/peers',
			'http://u:p@10.10.0.1:7780/peers', 'http://10.10.0.1/peers?x=1' ])
			assert.match(url, load({ ...SPOKE, discovery: url }).data?.discovery, url);
	});

	// uclient refuses a scheme in capitals, and has no TLS context for https.
	it('refuses anything else, before any interface is looked up', () => {
		for (let url in [ 'https://10.10.0.1:7780/peers', 'HTTP://10.10.0.1:7780/peers', 'ftp://10.10.0.1/peers',
			'10.10.0.1:7780/peers', ' http://10.10.0.1:7780/peers', 'http://10.10.0.1:0/peers',
			'http://10.10.0.1:65536/peers', 'http://u:p/a@10.10.0.1/peers', 'http://[10.10.0.1]/peers', 'http:///peers' ])
			assert.match(contains({ ok: false, error: 'CONFIG_INVALID_OPTION',
				details: 'discovery must be a URL of the form http://<host>[:<port>]/<path>' }),
				load({ ...SPOKE, discovery: url }, {}), url);
	});
});

describe('config: hub', () => {
	it('loads the role file without peers or mode', () => {
		assert.match({ role: 'hub', read_iface: 'wg_mesh', serve_addr: '10.10.0.1', serve_port: '7780',
			overrides: {}, leftovers: [] },
			load(HUB_ROLE).data);
	});

	it('requires every hub option', () => {
		for (let opt in [ 'read_iface', 'serve_addr', 'serve_port' ])
			assert.match(contains({ ok: false, error: 'CONFIG_MISSING_OPTION', details: opt }),
				load({ ...HUB_ROLE, [opt]: null }));
	});

	it('refuses when the read interface does not exist', () => {
		assert.match(contains({ ok: false, error: 'INTERFACE_MISSING', details: 'wg_mesh' }),
			load(HUB_ROLE, { wg_hub: IFACES.wg_hub }));
	});

	// socket.listen binds a wildcard for 0.0.0.0 and ::, and resolves a name with a blocking DNS lookup.
	it('refuses a serve_addr that is not one literal address the router can hold', () => {
		for (let bad in [ '0.0.0.0', '0.1.2.3', '::', 'localhost', 'hub.example.org', '*', '224.0.0.1', 'ff02::1',
			'255.255.255.255', 'fe80::1', 'fe80::1%wg_hub', ' 10.10.0.1', '10.10.0.1 ', '10.10.0.1/24', '[2001:db8::1]', '010.10.0.1' ])
			assert.match(contains({ ok: false, error: 'CONFIG_INVALID_OPTION',
				details: 'serve_addr must be an IP address of the router, not unspecified or multicast' }),
				load({ ...HUB_ROLE, serve_addr: bad }), bad);
	});

	it('takes serve_addr in its canonical form', () => {
		let cases = { '10.10.0.1': '10.10.0.1', '127.0.0.1': '127.0.0.1', '2001:DB8:0:0::1': '2001:db8::1',
			'fd00:1::1': 'fd00:1::1', '::1': '::1' };
		for (let given, canonical in cases)
			assert.match(canonical, load({ ...HUB_ROLE, serve_addr: given }).data.serve_addr, given);
	});

	// socket.listen reads `0` as any free port, `0x50` as 80 and ` 22 ` as 22.
	it('refuses a serve_port that is not a decimal port number', () => {
		for (let bad in [ '0', '00', '0x50', ' 22 ', '22 ', '07780', '65536', '70000', '-1', '80.5', '1e3', 'http' ])
			assert.match(contains({ ok: false, error: 'CONFIG_INVALID_OPTION', details: 'serve_port must be a port number from 1 to 65535' }),
				load({ ...HUB_ROLE, serve_port: bad }), bad);
		for (let good in [ '1', '7780', '65535' ])
			assert.match(good, load({ ...HUB_ROLE, serve_port: good }).data.serve_port, good);
	});
});

describe('config: parameter overrides', () => {
	it('reads positive numbers for any parameter, in both roles', () => {
		assert.match({ cycle: 1, trial_window: 2.5, discovery_interval: 10 },
			load({ ...SPOKE, cycle: '1', trial_window: '2.5', discovery_interval: '10' }).data.overrides);
		assert.match({ cycle: 1.5 }, load({ ...HUB_ROLE, cycle: '1.5' }).data.overrides);
	});

	// The fast parameters of the e2e lab (devenv/services/e2e/node.sh) and its mixed scenario.
	it('takes the parameters the lab runs with', () => {
		let lab = { cycle: '1', n_up: '3', m_down: '2', tunnel_timeout: '1', trial_window: '4', backoff_min: '4',
			backoff_max: '16', backoff_reset: '30', discovery_interval: '5' };
		assert.match({ cycle: 1, n_up: 3, m_down: 2, tunnel_timeout: 1, trial_window: 4, backoff_min: 4, backoff_max: 16,
			backoff_reset: 30, discovery_interval: 5 }, load({ ...SPOKE, ...lab }).data.overrides);
		for (let over in [ { backoff_min: '2', backoff_max: '4' }, { backoff_min: '300', backoff_max: '300' } ])
			assert.match(contains({ ok: true }), load({ ...SPOKE, ...lab, ...over }), over);
		assert.match(contains({ ok: true }), load({ ...HUB_ROLE, cycle: '1' }));
	});

	it('takes each bound itself, and refuses what lies beyond it', () => {
		let cases = {
			cycle: [ '1', '10', '0.9', '10.5', 'cycle must be a number from 1 to 10' ],
			n_up: [ '1', '100', '0', '101', 'n_up must be a whole number from 1 to 100' ],
			m_down: [ '1', '100', '0', '101', 'm_down must be a whole number from 1 to 100' ],
			tunnel_timeout: [ '0.1', '5', '0.09', '5.01', 'tunnel_timeout must be a number from 0.1 to 5' ],
			trial_window: [ '60', '60', '0.5', '61', 'trial_window must be a number from 1 to 60' ],
			backoff_min: [ '1', '900', '0.5', '86401', 'backoff_min must be a number from 1 to 86400' ],
			backoff_max: [ '30', '86400', '0.5', '86401', 'backoff_max must be a number from 1 to 86400' ],
			backoff_reset: [ '1', '86400', '0.5', '86401', 'backoff_reset must be a number from 1 to 86400' ],
			discovery_interval: [ '5', '86400', '4.9', '86401', 'discovery_interval must be a number from 5 to 86400' ],
			give_up_after: [ '1', '100', '0', '101', 'give_up_after must be a whole number from 1 to 100' ],
			give_up_pause: [ '60', '604800', '59.5', '604801', 'give_up_pause must be a number from 60 to 604800' ],
		};
		let roomy = { ...SPOKE, trial_window: '60' };
		for (let name, c in cases) {
			for (let good in [ c[0], c[1] ])
				assert.match(+good, load({ ...roomy, [name]: good }).data?.overrides[name], `${name} ${good}`);
			for (let bad in [ c[2], c[3] ])
				assert.match(contains({ ok: false, error: 'CONFIG_INVALID_OPTION', details: c[4] }),
					load({ ...roomy, [name]: bad }), `${name} ${bad}`);
		}
	});

	// int(cycle * 1000) was a 0 ms timer for 0.0001, and NaN for a number too large to hold.
	it('refuses the values that ran the loop without pause or past the watchdog', () => {
		for (let c in [ [ 'cycle', '0.0001' ], [ 'cycle', '99999999999999999999999' ], [ 'cycle', '3600' ],
			[ 'tunnel_timeout', '600' ], [ 'n_up', '0.1' ], [ 'm_down', '2.5' ], [ 'n_up', '1.0' ] ])
			assert.match(contains({ ok: false, error: 'CONFIG_INVALID_OPTION' }), load({ ...SPOKE, [c[0]]: c[1] }), c);
	});

	it('ignores options that are not parameters', () => {
		assert.match({}, load({ ...SPOKE, foo: '3' }).data.overrides);
	});

	it('rejects a value that is not a decimal number, naming the option', () => {
		for (let bad in [ '0', '0.0', '-1', 'abc', '', '1e3', ' 3', '3s', '0x10', '3\n', [ '3' ] ])
			assert.match(contains({ ok: false, error: 'CONFIG_INVALID_OPTION', details: 'cycle must be a number from 1 to 10' }),
				load({ ...SPOKE, cycle: bad }), bad);
	});

	it('refuses a backoff_max below backoff_min, the default included', () => {
		assert.match(contains({ ok: false, error: 'CONFIG_INVALID_OPTION', details: 'backoff_max must be at least backoff_min (900)' }),
			load({ ...SPOKE, backoff_min: '900', backoff_max: '30' }));
		assert.match(contains({ ok: false, error: 'CONFIG_INVALID_OPTION', details: 'backoff_max must be at least backoff_min (30)' }),
			load({ ...SPOKE, backoff_max: '20' }));
		assert.match(contains({ ok: true }), load({ ...SPOKE, backoff_min: '60', backoff_max: '60' }));
	});

	it('refuses a trial_window that no answer can come back within', () => {
		assert.match(contains({ ok: false, error: 'CONFIG_INVALID_OPTION', details: 'trial_window must be longer than cycle + tunnel_timeout (4)' }),
			load({ ...SPOKE, trial_window: '4' }));
		assert.match(contains({ ok: false, error: 'CONFIG_INVALID_OPTION', details: 'trial_window must be longer than cycle + tunnel_timeout (11.5)' }),
			load({ ...SPOKE, cycle: '10', tunnel_timeout: '1.5' }));
		assert.match(contains({ ok: true }), load({ ...SPOKE, trial_window: '4.5' }));
	});

	it('holds a hub, which uses only cycle, to the bounds alone', () => {
		assert.match(contains({ ok: true }), load({ ...HUB_ROLE, cycle: '10', backoff_max: '1' }));
		assert.match(contains({ ok: false, details: 'cycle must be a number from 1 to 10' }), load({ ...HUB_ROLE, cycle: '0.5' }));
	});
});

describe('config: steered peers', () => {
	it('manages a mesh peer with settings, with canonical relay and tunnel', () => {
		let peers = peers_of([ SPOKE_B_PEER ], [ settings(SPOKE_B, '[FD42:0::12]:51820', 'FD42:2:0::12') ]);
		assert.match([ { section: 'peer0', pubkey: SPOKE_B, relay: '[fd42::12]:51820', tunnel: 'fd42:2::12' } ], peers.managed);
		assert.match([ [], [] ], [ peers.unmanaged, peers.stale ]);
	});

	it('leaves a mesh peer without settings, the hub peer with its fixed endpoint, unmanaged by section', () => {
		let peers = peers_of([ SPOKE_B_PEER, HUB_PEER ], [ SPOKE_B_SETTINGS ]);
		assert.match([ { section: 'peer0', pubkey: SPOKE_B, relay: '10.10.0.12:51820', tunnel: '10.20.0.12' } ], peers.managed);
		assert.match([ { section: 'peer1', pubkey: HUB, reason: 'fixed endpoint' } ], peers.unmanaged);
	});

	// A roamer gives the anchor its stable address, so that the two meet without wgpathd too.
	it('steers a peer with a fixed endpoint once it has settings', () => {
		let anchor = { ...SPOKE_B_PEER, endpoint_host: '2001:db8:b::1', endpoint_port: '51820' };
		let peers = peers_of([ anchor ], [ SPOKE_B_SETTINGS ]);
		assert.match([ { section: 'peer0', pubkey: SPOKE_B, relay: '10.10.0.12:51820', tunnel: '10.20.0.12' } ], peers.managed);
		assert.match([], peers.unmanaged);
	});

	it('takes an empty endpoint_host as no fixed endpoint', () => {
		assert.match([ 'not configured' ], map(peers_of([ { ...HUB_PEER, endpoint_host: '' } ], []).unmanaged, (u) => u.reason));
	});

	it('gives the reason a peer is left alone', () => {
		let cases = {
			'invalid public_key':        [ mesh_peer('nope'), [ settings('nope', '10.10.0.11:51820', '10.20.0.11') ] ],
			'not configured':            [ mesh_peer(SPOKE_A), [] ],
			'fixed endpoint':            [ { ...mesh_peer(SPOKE_A), endpoint_host: '192.0.2.11' }, [] ],
			'configured more than once': [ mesh_peer(SPOKE_A), [ settings(SPOKE_A, '10.10.0.11:51820', '10.20.0.11'),
				settings(SPOKE_A, '10.10.0.11:51820', '10.20.0.11') ] ],
			'missing relay':             [ mesh_peer(SPOKE_A), [ settings(SPOKE_A, null, '10.20.0.11') ] ],
			'invalid relay':             [ mesh_peer(SPOKE_A), [ settings(SPOKE_A, '10.10.0.11', '10.20.0.11') ] ],
			'missing tunnel':            [ mesh_peer(SPOKE_A), [ settings(SPOKE_A, '10.10.0.11:51820', null) ] ],
			'invalid tunnel':            [ mesh_peer(SPOKE_A), [ settings(SPOKE_A, '10.10.0.11:51820', '10.20.0.11:1') ] ],
		};
		for (let reason, c in cases) {
			let peers = peers_of([ SPOKE_B_PEER, c[0] ], [ SPOKE_B_SETTINGS, ...c[1] ]);
			assert.match(1, length(peers.managed), reason);
			assert.match([ { section: 'peer1', pubkey: c[0].public_key, reason: reason } ], peers.unmanaged, reason);
		}
	});

	it('finds a peer\'s settings by its public key, whatever its section is called', () => {
		let res = load(SPOKE, { ...IFACES, cfg09cdcd: SPOKE_B_PEER, spoke_b: HUB_PEER }, [ SPOKE_B_SETTINGS ]);
		assert.match([ [ 'cfg09cdcd', SPOKE_B ] ], map(res.data.peers.managed, (p) => [ p.section, p.pubkey ]));
		assert.match([ [ 'spoke_b', 'fixed endpoint' ] ], map(res.data.peers.unmanaged, (p) => [ p.section, p.reason ]));
	});

	it('ignores wireguard peers of other interfaces, and takes their settings as stale', () => {
		let other = { ...SPOKE_B_PEER, '.type': 'wireguard_wg_hub' };
		assert.match({ managed: [], unmanaged: [], stale: [ { pubkey: SPOKE_B } ] }, peers_of([ other ], [ SPOKE_B_SETTINGS ]));
	});

	it('lists settings that match no mesh peer as stale, once per key, and steers nothing with them', () => {
		let stray = settings(SPOKE_A, '10.10.0.11:51820', '10.20.0.11');
		let peers = peers_of([ SPOKE_B_PEER ], [ stray, SPOKE_B_SETTINGS, stray, { '.type': 'peer', relay: '10.0.0.1:1' } ]);
		assert.match([ SPOKE_B ], map(peers.managed, (p) => p.pubkey));
		assert.match([ { pubkey: SPOKE_A }, { pubkey: null } ], peers.stale);
	});

	// A key of 43 digits and a padding sign is a valid key: one per peer.
	prop('never fails the config for bad peers', gen.array(gen.tuple(gen.bool(), gen.bool(), gen.bool()), { max_len: 6 }), (specs) => {
		let key = (i) => sprintf('%043d=', i);
		let mesh = [], peers = [];
		for (let i = 0; i < length(specs); i++) {
			let p = specs[i];
			push(mesh, mesh_peer(p[0] ? key(i) : 'bad'));
			push(peers, settings(key(i), p[1] ? '10.10.0.12:51820' : 'x', p[2] ? '10.20.0.12' : null));
		}
		let loaded = peers_of(mesh, peers);
		let good = length(filter(specs, (p) => p[0] && p[1] && p[2]));
		assert.match(good, length(loaded.managed));
		assert.match(length(specs) - good, length(loaded.unmanaged));
		assert.match(length(filter(specs, (p) => !p[0])), length(loaded.stale));
	});
});

describe('config: options left over in network', () => {
	const LEGACY = { ...SPOKE_B_PEER, wgpathd_relay: '10.10.0.12:51820', wgpathd_tunnel: '10.20.0.12' };

	it('reads no settings from network: a peer with the old options alone is not configured', () => {
		let peers = peers_of([ LEGACY ], []);
		assert.match([ [], [ 'not configured' ] ], [ peers.managed, map(peers.unmanaged, (u) => u.reason) ]);
	});

	it('names each network section that still has them, in both roles', () => {
		let network = { ...IFACES, spoke_b: LEGACY, hub: { ...HUB_PEER, wgpathd_tunnel: '10.20.0.1' } };
		let expected = [ { section: 'spoke_b', options: [ 'wgpathd_relay', 'wgpathd_tunnel' ] },
			{ section: 'hub', options: [ 'wgpathd_tunnel' ] } ];
		assert.match(expected, load(SPOKE, network).data.leftovers);
		assert.match(expected, load(HUB_ROLE, network).data.leftovers);
	});

	it('names none when network has none', () => {
		assert.match([], load(SPOKE, { ...IFACES, spoke_b: SPOKE_B_PEER }, [ SPOKE_B_SETTINGS ]).data.leftovers);
	});
});
