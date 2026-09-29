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

function steered(pubkey, relay, tunnel) {
	return { '.type': 'wireguard_wg_mesh', public_key: pubkey, allowed_ips: [ '10.12.0.0/16' ],
		wgpathd_relay: relay, wgpathd_tunnel: tunnel };
}

const SPOKE_B_PEER = steered(SPOKE_B, '10.10.0.12:51820', '10.20.0.12');
const HUB_PEER  = { '.type': 'wireguard_wg_mesh', public_key: HUB, endpoint_host: '2001:db8:100::1' };

function load(main, network) {
	let res;
	with_context({ uci: { data: { wgpathd: { main: main }, network: network ?? IFACES } } }, (deps) => {
		res = config.load(deps);
	});
	return res;
}

function peers_of(...sections) {
	let network = { ...IFACES };
	for (let i = 0; i < length(sections); i++)
		network[`peer${i}`] = sections[i];
	return load(SPOKE, network).data.peers;
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
			peers: { managed: [], unmanaged: [] } },
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
		let res = load(SPOKE, { ...IFACES, cfg09cdcd: SPOKE_B_PEER });
		assert.match([ 'cfg09cdcd' ], map(res.data.peers.managed, (p) => p.section));
	});
});

describe('config: hub', () => {
	it('loads the role file without peers or mode', () => {
		assert.match({ role: 'hub', read_iface: 'wg_mesh', serve_addr: '10.10.0.1', serve_port: '7780',
			overrides: {} },
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
});

describe('config: parameter overrides', () => {
	it('reads positive numbers for any parameter, in both roles', () => {
		assert.match({ cycle: 1, trial_window: 2.5, discovery_interval: 10 },
			load({ ...SPOKE, cycle: '1', trial_window: '2.5', discovery_interval: '10' }).data.overrides);
		assert.match({ cycle: 0.5 }, load({ ...HUB_ROLE, cycle: '0.5' }).data.overrides);
	});

	it('ignores options that are not parameters', () => {
		assert.match({}, load({ ...SPOKE, foo: '3' }).data.overrides);
	});

	it('rejects a value that is not a positive number, naming the option', () => {
		for (let bad in [ '0', '0.0', '-1', 'abc', '', '1e3', ' 3', '3s', [ '3' ] ])
			assert.match(contains({ ok: false, error: 'CONFIG_INVALID_OPTION', details: 'n_up must be a positive number' }),
				load({ ...SPOKE, n_up: bad }), bad);
	});
});

describe('config: steered peers', () => {
	it('manages an annotated peer, with canonical relay and tunnel', () => {
		let peers = peers_of(steered(SPOKE_B, '[FD42:0::12]:51820', 'FD42:2:0::12'));
		assert.match([ { section: 'peer0', pubkey: SPOKE_B, relay: '[fd42::12]:51820', tunnel: 'fd42:2::12' } ], peers.managed);
		assert.match([], peers.unmanaged);
	});

	it('leaves the static hub peer unmanaged, by section', () => {
		let peers = peers_of(SPOKE_B_PEER, HUB_PEER);
		assert.match([ { section: 'peer0', pubkey: SPOKE_B, relay: '10.10.0.12:51820', tunnel: '10.20.0.12' } ], peers.managed);
		assert.match([ { section: 'peer1', pubkey: HUB, reason: 'missing wgpathd_relay' } ], peers.unmanaged);
	});

	it('gives the reason a peer is left alone', () => {
		let cases = {
			'invalid public_key':     steered('nope', '10.10.0.12:51820', '10.20.0.12'),
			'missing wgpathd_relay':  steered(SPOKE_A, null, '10.20.0.11'),
			'invalid wgpathd_relay':  steered(SPOKE_A, '10.10.0.11', '10.20.0.11'),
			'missing wgpathd_tunnel': steered(SPOKE_A, '10.10.0.11:51820', null),
			'invalid wgpathd_tunnel': steered(SPOKE_A, '10.10.0.11:51820', '10.20.0.11:1'),
		};
		for (let reason, section in cases) {
			let peers = peers_of(SPOKE_B_PEER, section);
			assert.match(1, length(peers.managed), reason);
			assert.match(reason, peers.unmanaged[0].reason);
		}
	});

	it('ignores wireguard peers of other interfaces', () => {
		let other = { ...SPOKE_B_PEER, '.type': 'wireguard_wg_hub' };
		assert.match({ managed: [], unmanaged: [] }, peers_of(other));
	});

	prop('never fails the config for bad peers', gen.array(gen.tuple(gen.bool(), gen.bool(), gen.bool()), { max_len: 6 }), (specs) => {
		let sections = map(specs, (p) => steered(p[0] ? SPOKE_B : 'bad', p[1] ? '10.10.0.12:51820' : 'x', p[2] ? '10.20.0.12' : null));
		let peers = peers_of(...sections);
		let good = length(filter(specs, (p) => p[0] && p[1] && p[2]));
		assert.match(good, length(peers.managed));
		assert.match(length(specs) - good, length(peers.unmanaged));
	});
});

