import { describe, it, assert } from 'utest';
import * as h from 'lib.helpers';
import * as check from 'wgpathd.check';
import * as config from 'wgpathd.config';
import * as daemon from 'wgpathd.daemon';
import * as params from 'wgpathd.params';
import * as Result from 'wgpathd.result';

// The configuration of the first real deployment, one hub and two spokes, with
// documentation addresses in place of the public IPv6 ones: every check added since
// must take it as it is, with the default timing.

const SPOKE_A      = 'ckRTxoRCqAhiHEgHPnhfpN6nU5/F2QmMe0nJ2kt7PFc=';
const SPOKE_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const HUB       = 'W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=';

const DIRECT = { [SPOKE_A]: '[2001:db8:ca::1]:51820', [SPOKE_B]: '[2001:db8:5e::1]:51820' };

const SPOKES = {
	spoke_a:      { key: SPOKE_A, hub_iface: 'legacy_a', relay: '10.10.0.11', tunnel: '10.20.0.11' },
	spoke_b: { key: SPOKE_B, hub_iface: 'legacy_b', relay: '10.10.0.12', tunnel: '10.20.0.12' },
};

function spoke_main(name) {
	return { '.type': 'wgpathd', enabled: '1', role: 'spoke', mode: 'steer', mesh_iface: 'wg_mesh',
		hub_iface: SPOKES[name].hub_iface, discovery: 'http://10.10.0.1:7780/peers' };
}

const HUB_MAIN = { '.type': 'wgpathd', enabled: '1', role: 'hub', read_iface: 'wg_mesh',
	serve_addr: '10.10.0.1', serve_port: '7780' };

// A spoke's network: its two tunnels, the other spoke annotated, and the hub as a
// mesh peer without annotations.
function spoke_network(name) {
	let self = SPOKES[name];
	let net = {
		wg_mesh: { '.type': 'interface', proto: 'wireguard', addresses: [ `${self.tunnel}/24` ] },
		[self.hub_iface]: { '.type': 'interface', proto: 'wireguard', addresses: [ `${self.relay}/24` ] },
		wgmesh_hub: { '.type': 'wireguard_wg_mesh', public_key: HUB, endpoint_host: '2001:db8:4b::1',
			endpoint_port: '51820' },
	};
	for (let other, peer in SPOKES)
		if (other != name)
			net[`wgmesh_${other}`] = { '.type': 'wireguard_wg_mesh', public_key: peer.key,
				wgpathd_relay: `${peer.relay}:51820`, wgpathd_tunnel: peer.tunnel };
	return net;
}

const HUB_NETWORK = {
	wg_mesh: { '.type': 'interface', proto: 'wireguard', addresses: [ '10.20.0.1/24' ] },
	wg_hub:  { '.type': 'interface', proto: 'wireguard', addresses: [ '10.10.0.1/24' ] },
	wgmesh_spoke_a:      { '.type': 'wireguard_wg_mesh', public_key: SPOKE_A },
	wgmesh_spoke_b: { '.type': 'wireguard_wg_mesh', public_key: SPOKE_B },
};

function kernel_of(...keys_) {
	let k = {};
	for (let key in keys_)
		k[key] = { hs: 0 };
	return k;
}

// The relays and the hub are reached through the hub tunnel, everything else through the WAN.
function route_via(hub_iface) {
	return (host) => Result.ok({ oif: (index(host, '10.10.0.') == 0) ? hub_iface : 'pppoe-wan', local: false });
}

function run_check(main, net, status) {
	let deps = {
		uci: h.uci({ wgpathd: { main: main }, network: net }).cursor(),
		ubus: h.ubus((obj, method) => (obj == 'wireguard' && method == 'status') ? Result.ok(status) : die('unexpected')),
		route_get: route_via(main.hub_iface ?? 'wg_hub'),
	};
	return check.run(deps);
}

describe('deployment: service wgpathd check', () => {
	it('passes both spokes without a warning', () => {
		for (let name, self in SPOKES) {
			let other = (name == 'spoke_a') ? SPOKES.spoke_b : SPOKES.spoke_a;
			let res = run_check(spoke_main(name), spoke_network(name), {
				...h.status_reply('wg_mesh', kernel_of(other.key, HUB)),
				...h.status_reply(self.hub_iface, kernel_of(HUB)),
			});
			assert.match(true, res.ok, name);
			assert.match([ 'ok', 'ok', 'ok', 'ok', 'skip' ], map(res.findings, (f) => f.level), res.report);
			let peer = (name == 'spoke_a') ? 'wgmesh_spoke_b' : 'wgmesh_spoke_a';
			assert.match(`ok    peer ${peer}: relay ${other.relay}:51820 via ${self.hub_iface}, probes ${other.tunnel}`,
				split(res.report, '\n')[3], name);
		}
	});

	it('passes the hub without a warning', () => {
		let res = run_check(HUB_MAIN, HUB_NETWORK, h.status_reply('wg_mesh', kernel_of(SPOKE_A, SPOKE_B)));
		assert.match(true, res.ok);
		assert.match([ 'ok', 'ok' ], map(res.findings, (f) => f.level), res.report);
	});
});

describe('deployment: the daemon', () => {
	function start(w, cfg) {
		let d = daemon.create(w.deps, cfg, params.build(cfg));
		let started = null;
		d.start((res) => { started = res; });
		assert.match(true, started?.ok, 'started');
		return d;
	}

	function spoke(name) {
		let self = SPOKES[name];
		let other = (name == 'spoke_a') ? SPOKES.spoke_b : SPOKES.spoke_a;
		let loaded = config.load({ uci: h.uci({ wgpathd: { main: spoke_main(name) }, network: spoke_network(name) }).cursor() });
		assert.match(true, loaded.ok, name);
		let w = h.world({ [other.key]: { endpoint: null, hs: 0 }, [HUB]: { endpoint: '[2001:db8:4b::1]:51820', hs: 0 } });
		w.deps.route_get = route_via(self.hub_iface);
		w.payload = sprintf('%J', { [SPOKE_A]: { direct: DIRECT[SPOKE_A] }, [SPOKE_B]: { direct: DIRECT[SPOKE_B] },
			[HUB]: { direct: '[2001:db8:4b::1]:51820' } });
		w.reachable[substr(split(DIRECT[other.key], ']')[0], 1)] = true;
		w.reachable[other.tunnel] = true;
		return { w: w, d: start(w, loaded.data), key: other.key };
	}

	it('takes each spoke\'s candidate and brings the other spoke to DIRECT with the default timing', () => {
		for (let name in keys(SPOKES)) {
			let s = spoke(name);
			for (let i = 0; i < 10; i++) {
				s.d.cycle(() => null);
				s.w.clock.advance(3);
			}
			let peer = s.d.status().peers[s.key];
			assert.match([ 'DIRECT', DIRECT[s.key], null ], [ peer.state, s.w.kernel[s.key].endpoint, peer.candidate_refused ], name);
			assert.match([], s.w.logs.matching(/refused|failed/), name);
		}
	});

	it('publishes both spokes from the hub', () => {
		let loaded = config.load({ uci: h.uci({ wgpathd: { main: HUB_MAIN }, network: HUB_NETWORK }).cursor() });
		assert.match(true, loaded.ok);
		let w = h.world({ [SPOKE_A]: { endpoint: DIRECT[SPOKE_A], hs: 1790456490 }, [SPOKE_B]: { endpoint: DIRECT[SPOKE_B], hs: 1790456480 } });
		let d = start(w, loaded.data);
		assert.match({ [SPOKE_A]: { direct: DIRECT[SPOKE_A], handshake_age: 10 }, [SPOKE_B]: { direct: DIRECT[SPOKE_B], handshake_age: 20 } },
			d.status().peers);
	});
});
