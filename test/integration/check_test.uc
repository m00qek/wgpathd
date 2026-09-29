import { describe, it, assert } from 'utest';
import * as h from 'lib.helpers';
import * as check from 'wgpathd.check';
import * as Result from 'wgpathd.result';

const SPOKE_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const SPOKE_A = 'ckRTxoRCqAhiHEgHPnhfpN6nU5/F2QmMe0nJ2kt7PFc=';
const HUB  = 'W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=';

const SPOKE = { '.type': 'wgpathd', role: 'spoke', mesh_iface: 'wg_mesh', hub_iface: 'wg_hub',
	discovery: 'http://192.0.2.1:7780/peers', mode: 'steer' };
const HUB_MAIN = { '.type': 'wgpathd', role: 'hub', read_iface: 'wg_mesh', serve_addr: '192.0.2.1',
	serve_port: '7780' };

function network(extra) {
	return {
		wg_mesh: { '.type': 'interface', proto: 'wireguard' },
		wg_hub:  { '.type': 'interface', proto: 'wireguard', addresses: [ '192.0.2.1/24' ] },
		spoke_b: { '.type': 'wireguard_wg_mesh', public_key: SPOKE_B },
		hub:  { '.type': 'wireguard_wg_mesh', public_key: HUB },
		...(extra ?? {}),
	};
}

// The `peer` sections of /etc/config/wgpathd: spoke_b's, and any extra ones.
function peers(...extra) {
	let out = { cfg01a2b3: { '.type': 'peer', public_key: SPOKE_B, relay: '10.10.0.12:51820', tunnel: '10.20.0.12' } };
	for (let i = 0; i < length(extra); i++)
		out[`cfg1${i}a2b3`] = { '.type': 'peer', ...extra[i] };
	return out;
}

function kernel_of(keys_) {
	let k = {};
	for (let key in keys_)
		k[key] = { hs: 0 };
	return k;
}

// status: the `wireguard status` answer (a reply object or a Result error); routes: host -> oif or false;
// peers: the `peer` sections; firewall: /etc/config/firewall, none when not given; files: what fs holds.
function run(main, net, opts) {
	opts ??= {};
	let status = opts.status ?? Result.ok({
		...h.status_reply('wg_mesh', kernel_of([ SPOKE_B, HUB ])),
		...h.status_reply('wg_hub', kernel_of([ HUB ])),
	});
	let routes = opts.routes ?? {};
	let config = { wgpathd: { main: main, ...(opts.peers ?? peers()) }, network: net ?? network(), firewall: opts.firewall };
	let deps = {
		uci: h.uci(config).cursor(),
		fs: h.fs(opts.files ?? {}),
		ubus: h.ubus((obj, method) => (obj == 'wireguard' && method == 'status') ? status : die('unexpected')),
		route_get: (host) => (routes[host] === false)
			? Result.err('ROUTE_LOOKUP_FAILED', `${host}: Network unreachable`)
			: Result.ok({ oif: routes[host] ?? 'wg_hub' }),
	};
	return check.run(deps, { config_only: opts.config_only });
}

describe('check: config only', () => {
	it('reports the loaded config and passes', () => {
		let res = run(SPOKE, null, { config_only: true });
		assert.match(true, res.ok);
		assert.match('ok    config: spoke, mode steer, 1 steered peer, 1 not steered\n', res.report);
	});

	it('fails with the loader reason, in words', () => {
		let cases = [
			[ { '.type': 'wgpathd', enabled: '0' }, "option role must be 'spoke' or 'hub' (is unset)" ],
			[ { ...SPOKE, discovery: null }, 'missing option discovery' ],
			[ { ...SPOKE, cycle: 'fast' }, 'option cycle must be a number from 1 to 10' ],
			[ { ...SPOKE, hub_iface: 'wg_nope' }, 'no interface wg_nope in /etc/config/network' ],
			[ { ...SPOKE, mesh_iface: '@interface[0]' }, 'option mesh_iface must be an interface name of letters, digits and _' ],
			[ { ...HUB_MAIN, serve_addr: '0.0.0.0' }, 'option serve_addr must be an IP address of the router, not unspecified or multicast' ],
			[ { ...HUB_MAIN, serve_port: '0x50' }, 'option serve_port must be a port number from 1 to 65535' ],
		];
		for (let c in cases) {
			let res = run(c[0], null, { config_only: true });
			assert.match([ false, `FAIL  config: ${c[1]}\n` ], [ res.ok, res.report ], c[1]);
		}
	});

	it('warns about an unknown mode without failing', () => {
		let res = run({ ...SPOKE, mode: 'stear' }, null, { config_only: true });
		assert.match(true, res.ok);
		assert.match([ 'ok', 'warn' ], map(res.findings, (f) => f.level));
		assert.match("config: unknown mode 'stear' runs as observe", res.findings[1].message);
	});

	it('touches neither ubus nor routes', () => {
		let res = run(SPOKE, null, { config_only: true, status: Result.err('UBUS_CALL_FAILED', 'boom'),
			routes: { '10.10.0.12': 'wg_mesh' } });
		assert.match(true, res.ok);
		assert.match(1, length(res.findings));
	});
});

describe('check: full, spoke', () => {
	it('checks interfaces, relay routes and peer settings', () => {
		let res = run(SPOKE);
		assert.match(true, res.ok);
		assert.match(
			'ok    config: spoke, mode steer, 1 steered peer, 1 not steered\n' +
			'ok    wg_mesh: up, 2 peers\n' +
			'ok    wg_hub: up, 1 peer\n' +
			'ok    peer spoke_b: relay 10.10.0.12:51820 via wg_hub, probes 10.20.0.12\n' +
			'skip  peer hub: not steered (not configured)\n' +
			'skip  firewall: no /etc/config/firewall, not checked\n',
			res.report);
	});

	it('fails on a relay routed into the mesh, on malformed settings and on settings given twice', () => {
		let net = network({ spoke_a: { '.type': 'wireguard_wg_mesh', public_key: SPOKE_A } });
		let extra = [ { public_key: SPOKE_A, relay: 'not-an-endpoint', tunnel: '10.20.0.11' },
			{ public_key: HUB, relay: '10.10.0.1:51820', tunnel: '10.20.0.1' },
			{ public_key: HUB, relay: '10.10.0.1:51820', tunnel: '10.20.0.1' } ];
		let res = run(SPOKE, net, { routes: { '10.10.0.12': 'wg_mesh' }, peers: peers(...extra) });
		assert.match(false, res.ok);
		assert.match([
			[ 'fail', 'peer spoke_b: relay routes into wg_mesh' ],
			[ 'fail', 'peer hub: not steered (configured more than once)' ],
			[ 'fail', 'peer spoke_a: not steered (invalid relay)' ],
		], map(filter(res.findings, (f) => f.level == 'fail'), (f) => [ f.level, f.message ]));
	});

	it('warns about settings for no mesh peer and about options left in network, and still passes', () => {
		let net = network({ hub: { '.type': 'wireguard_wg_mesh', public_key: HUB, wgpathd_relay: '10.10.0.1:51820' } });
		let res = run(SPOKE, net, { peers: peers({ public_key: SPOKE_A, relay: '10.10.0.11:51820', tunnel: '10.20.0.11' }) });
		assert.match(true, res.ok);
		assert.match([
			'config: network section hub: wgpathd_relay left over from an earlier version, ignored; ' +
				'run service wgpathd migrate or remove it',
			`peer settings for ${SPOKE_A}: no such peer in wg_mesh, ignored`,
		], map(filter(res.findings, (f) => f.level == 'warn'), (f) => f.message));
		assert.match('skip  peer hub: not steered (not configured)', split(trim(res.report), '\n')[-2]);
	});

	it('warns about a pending route lookup and a peer missing from the kernel', () => {
		let res = run(SPOKE, null, { routes: { '10.10.0.12': false },
			status: Result.ok({ ...h.status_reply('wg_mesh', {}), ...h.status_reply('wg_hub', {}) }) });
		assert.match(true, res.ok);
		assert.match([ 'warn', 'peer spoke_b: relay route lookup failed: ROUTE_LOOKUP_FAILED ' +
			'(10.10.0.12: Network unreachable) (retried every cycle)' ],
			[ res.findings[3].level, res.findings[3].message ]);

		res = run(SPOKE, null, { status: Result.ok({ ...h.status_reply('wg_mesh', {}), ...h.status_reply('wg_hub', {}) }) });
		assert.match([ 'warn', 'peer spoke_b: not in wg_mesh yet, skipped until it appears' ],
			[ res.findings[4].level, res.findings[4].message ]);
	});

	it('fails when the mesh interface is not in the kernel, but only warns for the hub interface', () => {
		let res = run(SPOKE, null, { status: Result.ok(h.status_reply('wg_hub', {})) });
		assert.match(false, res.ok);
		assert.match([ 'fail', 'wg_mesh: no interface wg_mesh' ], [ res.findings[1].level, res.findings[1].message ]);

		res = run(SPOKE, null, { status: Result.ok(h.status_reply('wg_mesh', kernel_of([ SPOKE_B ]))) });
		assert.match(true, res.ok);
		assert.match([ 'warn', 'wg_hub: no interface wg_hub' ], [ res.findings[2].level, res.findings[2].message ]);
	});

	it('fails when ubus answers but wireguard status does not', () => {
		let res = run(SPOKE, null, { status: Result.err('UBUS_CALL_FAILED', 'Not found') });
		assert.match(false, res.ok);
		assert.match('wg_mesh: UBUS_CALL_FAILED (Not found)', res.findings[1].message);
	});

	it('skips the interfaces when ubus is unreachable, and still checks the peers', () => {
		let res = run(SPOKE, null, { status: Result.err('UBUS_CONNECT_FAILED') });
		assert.match(true, res.ok);
		assert.match([ 'ok', 'skip', 'ok', 'skip', 'skip' ], map(res.findings, (f) => f.level));
		assert.match('ubus unavailable: interfaces not checked', res.findings[1].message);
	});

	it('warns that a disabled service will not start', () => {
		let res = run({ ...SPOKE, enabled: '0' });
		assert.match(true, res.ok);
		assert.match("service disabled (option enabled '0'): it will not start", res.findings[1].message);
	});
});

describe('check: discovery host', () => {
	let warnings = (res) => filter(res.findings, (f) => f.option == 'discovery');

	it('is quiet about an address routed through hub_iface', () => {
		assert.match([], warnings(run(SPOKE)));
	});

	it('warns about a host name, even for the config alone', () => {
		let expected = [ { level: 'warn', subject: 'config', option: 'discovery',
			message: 'config: discovery host hub.example.org is a name, not an address: every fetch waits for DNS' } ];
		let named = { ...SPOKE, discovery: 'http://hub.example.org:7780/peers' };
		assert.match(expected, warnings(run(named, null, { config_only: true })));
		assert.match(expected, warnings(run(named)));
	});

	it('warns about an address routed elsewhere than hub_iface, or not at all', () => {
		assert.match([ { level: 'warn', subject: 'config', option: 'discovery',
			message: 'config: discovery host 192.0.2.1 routes via eth0, not wg_hub' } ],
			warnings(run(SPOKE, null, { routes: { '192.0.2.1': 'eth0' } })));
		assert.match([ { level: 'warn', subject: 'config', option: 'discovery',
			message: 'config: discovery host 192.0.2.1: route lookup failed: ROUTE_LOOKUP_FAILED (192.0.2.1: Network unreachable)' } ],
			warnings(run(SPOKE, null, { routes: { '192.0.2.1': false } })));
		assert.match(true, run(SPOKE, null, { routes: { '192.0.2.1': 'eth0' } }).ok);
	});

	it('looks the host up in its canonical form', () => {
		assert.match([], warnings(run({ ...SPOKE, discovery: 'http://[FD00:0::1]:7780/peers' }, null, { routes: { 'FD00:0::1': 'eth0' } })));
	});
});

describe('check: full, hub', () => {
	it('checks the read interface', () => {
		let res = run(HUB_MAIN);
		assert.match(true, res.ok);
		assert.match('ok    config: hub, reads wg_mesh, serves 192.0.2.1:7780\nok    wg_mesh: up, 2 peers\n' +
			'skip  firewall: no /etc/config/firewall, not checked\n', res.report);
	});

	it('fails without the read interface', () => {
		let res = run(HUB_MAIN, null, { status: Result.ok(h.status_reply('wg_hub', {})) });
		assert.match(false, res.ok);
	});

	it('warns when serve_addr is no address of a WireGuard interface', () => {
		let lan = { lan: { '.type': 'interface', proto: 'static', ipaddr: '198.51.100.1', addresses: [ '198.51.100.1/24' ] } };
		let res = run({ ...HUB_MAIN, serve_addr: '198.51.100.1' }, network(lan));
		assert.match(true, res.ok);
		assert.match([ { level: 'warn', subject: 'config', option: 'serve_addr',
			message: 'config: serve_addr 198.51.100.1 is no address of a WireGuard interface in /etc/config/network' } ],
			filter(res.findings, (f) => f.option == 'serve_addr'));
	});

	it('finds serve_addr among the addresses of any WireGuard interface, however they are written', () => {
		let forms = [
			{ wg_hub: { '.type': 'interface', proto: 'wireguard', addresses: [ 'fd00:1::1/64', '192.0.2.1/24' ] } },
			{ wg_hub: { '.type': 'interface', proto: 'wireguard', addresses: '192.0.2.1/24 fd00:1::1/64' } },
			{ wg_hub: { '.type': 'interface', proto: 'wireguard', addresses: '192.0.2.1' } },
		];
		for (let extra in forms)
			assert.match([], filter(run(HUB_MAIN, network(extra)).findings, (f) => f.level == 'warn'), extra);
		assert.match([], filter(run({ ...HUB_MAIN, serve_addr: 'FD00:1:0::1' }, network(forms[0])).findings, (f) => f.level == 'warn'));
	});

	it('leaves serve_addr unwarned in a check of the config alone', () => {
		let res = run({ ...HUB_MAIN, serve_addr: '198.51.100.1' }, null, { config_only: true });
		assert.match([ 'ok' ], map(res.findings, (f) => f.level));
	});
});

describe('check: the firewall', () => {
	// A router whose zones but lan reject input, the WireGuard interfaces in `vpn`.
	function firewall(...rules) {
		return h.firewall({ '.type': 'defaults', input: 'REJECT', output: 'ACCEPT', forward: 'REJECT' },
			h.zone('lan', [ 'lan' ], 'ACCEPT'), h.zone('wan', [ 'wan', 'wan6' ], 'REJECT'),
			h.zone('vpn', [ 'wg_mesh', 'wg_hub' ], 'REJECT'), h.ALLOW_ICMPV6_INPUT, ...rules);
	}

	let net = network({ wg_mesh: { '.type': 'interface', proto: 'wireguard', listen_port: '51820', addresses: [ '10.20.0.11/24' ] } });
	let lines = (res) => filter(split(res.report, '\n'), (l) => match(l, /^\S+ +firewall:/));

	it('finds the rules a spoke needs in /etc/config/firewall', () => {
		let res = run(SPOKE, net, { firewall: firewall(...h.spoke_rules('vpn')) });
		assert.match([
			'ok    firewall: ICMP echo-request (tunnel probe) from wg_mesh (zone vpn): accepted',
			'ok    firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): accepted',
			'ok    firewall: ICMPv6 echo-request (underlay probe) from zone wan: accepted',
		], lines(res));
	});

	it('warns about a missing rule and prints it both ways, and still passes', () => {
		let res = run(SPOKE, net, { firewall: firewall(h.spoke_rules('vpn')[0]) });
		assert.match(true, res.ok);
		let from = index(res.report, 'warn  firewall:');
		assert.match(
			'warn  firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): no rule accepts it\n' +
			'      add it with:\n' +
			'        uci add firewall rule\n' +
			"        uci set firewall.@rule[-1].name='Allow-wgpathd-relay'\n" +
			"        uci set firewall.@rule[-1].src='vpn'\n" +
			"        uci set firewall.@rule[-1].proto='udp'\n" +
			"        uci set firewall.@rule[-1].dest_port='51820'\n" +
			"        uci set firewall.@rule[-1].target='ACCEPT'\n" +
			'        uci commit firewall\n' +
			'        service firewall reload\n' +
			'      or in /etc/config/firewall:\n' +
			'        config rule\n' +
			"        \toption name 'Allow-wgpathd-relay'\n" +
			"        \toption src 'vpn'\n" +
			"        \toption proto 'udp'\n" +
			"        \toption dest_port '51820'\n" +
			"        \toption target 'ACCEPT'\n",
			substr(res.report, from, index(res.report, 'ok    firewall: ICMPv6') - from));
	});

	it('follows the listen port of the mesh interface', () => {
		let moved = network({ wg_mesh: { '.type': 'interface', proto: 'wireguard', listen_port: '51000' } });
		let res = run(SPOKE, moved, { firewall: firewall(...h.spoke_rules('vpn')) });
		assert.match('warn  firewall: UDP port 51000 (relayed WireGuard) from wg_hub (zone vpn): no rule accepts it', lines(res)[1]);
		res = run(SPOKE, moved, { firewall: firewall(...h.spoke_rules('vpn', '51000')) });
		assert.match([], filter(res.findings, (f) => f.level == 'warn'));
	});

	it('cannot confirm what custom nftables rules or a firewall include may accept', () => {
		let chains = '## examples\n# chain user_pre_input {\n#     type filter hook input priority -1; policy accept;\n\n';
		let custom = { '/etc/nftables.d/10-custom-filter-chains.nft': chains,
			'/usr/share/nftables.d/chain-pre/input_vpn/50-wg.nft': 'udp dport 51820 accept\n' };
		assert.match('warn  firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): could not confirm, ' +
			'the firewall has custom nftables rules', lines(run(SPOKE, net, { firewall: firewall(), files: custom }))[1]);

		let elsewhere = { '/etc/nftables.d/10-custom-filter-chains.nft': chains,
			'/usr/share/nftables.d/chain-pre/forward/50-other.nft': 'accept\n' };
		assert.match('warn  firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): no rule accepts it',
			lines(run(SPOKE, net, { firewall: firewall(), files: elsewhere }))[1]);

		let include = firewall({ '.type': 'include', path: '/etc/firewall.user' });
		assert.match('warn  firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): could not confirm, ' +
			'the firewall has custom nftables rules', lines(run(SPOKE, net, { firewall: include }))[1]);
	});

	it('checks the hub\'s discovery port on the interface that holds serve_addr', () => {
		assert.match([ 'ok    firewall: TCP port 7780 (peer list) from wg_hub (zone vpn): accepted' ],
			lines(run(HUB_MAIN, null, { firewall: firewall(h.hub_rule('vpn')) })));
		assert.match('warn  firewall: TCP port 7780 (peer list) from wg_hub (zone vpn): no rule accepts it',
			lines(run(HUB_MAIN, null, { firewall: firewall() }))[0]);
	});

	it('leaves the firewall out of a check of the config alone', () => {
		assert.match([], lines(run(SPOKE, net, { config_only: true, firewall: firewall() })));
	});
});
