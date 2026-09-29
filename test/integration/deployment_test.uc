import { describe, it, assert } from 'utest';
import * as uci from 'uci';
import * as h from 'lib.helpers';
import * as check from 'wgpathd.check';
import * as config from 'wgpathd.config';
import * as daemon from 'wgpathd.daemon';
import * as migrate from 'wgpathd.migrate';
import * as params from 'wgpathd.params';
import * as Result from 'wgpathd.result';

// The configuration of the first real deployment, one hub and two spokes, with
// documentation addresses in place of the public IPv6 ones: every check added since
// must take it as it is, with the default timing. Each spoke is tried both as written
// afresh, the peer settings in /etc/config/wgpathd, and as releases up to 4 left it,
// the settings in /etc/config/network, once the migration has moved them.

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

function other_spoke(name) {
	return (name == 'spoke_a') ? SPOKES.spoke_b : SPOKES.spoke_a;
}

// A spoke's network: its two tunnels, the other spoke, and the hub as a mesh peer.
function spoke_network(name) {
	let self = SPOKES[name];
	let other = (name == 'spoke_a') ? 'spoke_b' : 'spoke_a';
	return {
		wg_mesh: { '.type': 'interface', proto: 'wireguard', listen_port: '51820', addresses: [ `${self.tunnel}/24` ] },
		[self.hub_iface]: { '.type': 'interface', proto: 'wireguard', addresses: [ `${self.relay}/24` ] },
		wgmesh_hub: { '.type': 'wireguard_wg_mesh', public_key: HUB, endpoint_host: '2001:db8:4b::1',
			endpoint_port: '51820' },
		[`wgmesh_${other}`]: { '.type': 'wireguard_wg_mesh', public_key: SPOKES[other].key },
	};
}

// The firewall the routers have: every zone rejects input, OpenWrt's default rules, the
// two WireGuard interfaces in a `mgmt` zone, and the rules the firewall how-to adds there.
function firewall(tunnels, rules) {
	return h.firewall(
		{ '.type': 'defaults', syn_flood: '1', input: 'REJECT', output: 'ACCEPT', forward: 'REJECT' },
		h.zone('lan', [ 'lan' ], 'REJECT'),
		h.zone('wan', [ 'wan', 'wan6' ], 'REJECT', { masq: '1', mtu_fix: '1', forward: 'DROP' }),
		h.zone('mgmt', tunnels, 'REJECT'),
		{ '.type': 'rule', name: 'Allow-DHCP-Renew', src: 'wan', proto: 'udp', dest_port: '68', target: 'ACCEPT', family: 'ipv4' },
		{ '.type': 'rule', name: 'Allow-Ping', src: 'wan', proto: 'icmp', icmp_type: 'echo-request', family: 'ipv4', target: 'ACCEPT' },
		{ '.type': 'rule', name: 'Allow-DHCPv6', src: 'wan', proto: 'udp', dest_port: '546', family: 'ipv6', target: 'ACCEPT' },
		h.ALLOW_ICMPV6_INPUT,
		{ '.type': 'rule', name: 'Allow-wg_mesh', src: 'wan', proto: 'udp', dest_port: '51820', family: 'ipv6', target: 'ACCEPT' },
		...rules);
}

function spoke_firewall(name, with_rules) {
	return firewall([ 'wg_mesh', SPOKES[name].hub_iface ], with_rules ? h.spoke_rules('mgmt') : []);
}

// A spoke configured afresh: the other spoke's settings in a `peer` section.
function fresh_spoke(name, with_rules) {
	let other = other_spoke(name);
	let peer = { '.type': 'peer', public_key: other.key, relay: `${other.relay}:51820`, tunnel: other.tunnel };
	return h.uci({ wgpathd: { main: spoke_main(name), cfg01a2b3: peer }, network: spoke_network(name),
		firewall: spoke_firewall(name, with_rules ?? true) }).cursor;
}

// A spoke as releases up to 4 left it, its settings options of the peer's network
// section, in real UCI files the migration then rewrites.
function migrated_spoke(name) {
	let other = other_spoke(name);
	let network = spoke_network(name);
	let section = (name == 'spoke_a') ? 'wgmesh_spoke_b' : 'wgmesh_spoke_a';
	network[section] = { ...network[section], wgpathd_relay: `${other.relay}:51820`, wgpathd_tunnel: other.tunnel };
	let dir = h.uci_dir({ wgpathd: { main: spoke_main(name) }, network: network, firewall: spoke_firewall(name, true) });
	assert.match(Result.ok(1), { ...migrate.run(uci.cursor(dir), h.logger().log) }, name);
	return () => uci.cursor(dir);
}

const LAYOUTS = { fresh: fresh_spoke, migrated: migrated_spoke };

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

function run_check(cursor, hub_iface, status) {
	let deps = {
		uci: cursor(),
		ubus: h.ubus((obj, method) => (obj == 'wireguard' && method == 'status') ? Result.ok(status) : die('unexpected')),
		route_get: route_via(hub_iface),
	};
	return check.run(deps);
}

describe('deployment: service wgpathd check', () => {
	for (let layout, make in LAYOUTS)
		it(`passes both spokes without a warning (${layout})`, () => {
			for (let name, self in SPOKES) {
				let other = other_spoke(name);
				let res = run_check(make(name), self.hub_iface, {
					...h.status_reply('wg_mesh', kernel_of(other.key, HUB)),
					...h.status_reply(self.hub_iface, kernel_of(HUB)),
				});
				assert.match(true, res.ok, name);
				assert.match([ 'ok', 'ok', 'ok', 'ok', 'skip', 'ok', 'ok', 'ok' ], map(res.findings, (f) => f.level), res.report);
				let peer = (name == 'spoke_a') ? 'wgmesh_spoke_b' : 'wgmesh_spoke_a';
				assert.match(`ok    peer ${peer}: relay ${other.relay}:51820 via ${self.hub_iface}, probes ${other.tunnel}`,
					split(res.report, '\n')[3], name);
				assert.match(`ok    firewall: UDP port 51820 (relayed WireGuard) from ${self.hub_iface} (zone mgmt): accepted`,
					split(res.report, '\n')[6], name);
			}
		});

	it('warns on both spokes about the two rules until they are added', () => {
		for (let name, self in SPOKES) {
			let other = other_spoke(name);
			let res = run_check(fresh_spoke(name, false), self.hub_iface, {
				...h.status_reply('wg_mesh', kernel_of(other.key, HUB)),
				...h.status_reply(self.hub_iface, kernel_of(HUB)),
			});
			assert.match(true, res.ok, name);
			assert.match([
				[ 'mesh_iface', 'firewall: ICMP echo-request (tunnel probe) from wg_mesh (zone mgmt): no rule accepts it' ],
				[ 'hub_iface', `firewall: UDP port 51820 (relayed WireGuard) from ${self.hub_iface} (zone mgmt): no rule accepts it` ],
			], map(filter(res.findings, (f) => f.level == 'warn'), (f) => [ f.option, f.message ]), name);
		}
	});

	let hub_check = (with_rule) => run_check(h.uci({ wgpathd: { main: HUB_MAIN }, network: HUB_NETWORK,
		firewall: firewall([ 'wg_mesh', 'wg_hub' ], with_rule ? [ h.hub_rule('mgmt') ] : []) }).cursor, 'wg_hub',
		h.status_reply('wg_mesh', kernel_of(SPOKE_A, SPOKE_B)));

	it('passes the hub without a warning', () => {
		let res = hub_check(true);
		assert.match(true, res.ok);
		assert.match([ 'ok', 'ok', 'ok' ], map(res.findings, (f) => f.level), res.report);
	});

	it('warns on the hub about the discovery rule until it is added', () => {
		assert.match([ [ 'serve_port', 'firewall: TCP port 7780 (peer list) from wg_hub (zone mgmt): no rule accepts it' ] ],
			map(filter(hub_check(false).findings, (f) => f.level == 'warn'), (f) => [ f.option, f.message ]));
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

	function spoke(name, cursor) {
		let self = SPOKES[name];
		let other = other_spoke(name);
		let loaded = config.load({ uci: cursor() });
		assert.match(true, loaded.ok, name);
		let w = h.world({ [other.key]: { endpoint: null, hs: 0 }, [HUB]: { endpoint: '[2001:db8:4b::1]:51820', hs: 0 } });
		w.deps.route_get = route_via(self.hub_iface);
		w.payload = sprintf('%J', { [SPOKE_A]: { direct: DIRECT[SPOKE_A] }, [SPOKE_B]: { direct: DIRECT[SPOKE_B] },
			[HUB]: { direct: '[2001:db8:4b::1]:51820' } });
		w.reachable[substr(split(DIRECT[other.key], ']')[0], 1)] = true;
		w.reachable[other.tunnel] = true;
		return { w: w, d: start(w, loaded.data), key: other.key };
	}

	for (let layout, make in LAYOUTS)
		it(`takes each spoke's candidate and brings the other spoke to DIRECT with the default timing (${layout})`, () => {
			for (let name in keys(SPOKES)) {
				let s = spoke(name, make(name));
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
