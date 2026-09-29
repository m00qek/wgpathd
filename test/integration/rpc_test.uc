import { describe, it, assert, contains } from 'utest';
import * as h from 'lib.helpers';
import * as rpc from 'wgpathd.rpc';
import * as check from 'wgpathd.check';
import { fix as firewall_fix } from 'wgpathd.firewall';
import * as params from 'wgpathd.params';
import * as Result from 'wgpathd.result';

const SPOKE_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const HUB  = 'W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=';
const PRIVATE = 'aGVsbG8gdGhpcyBpcyBub3QgYSByZWFsIGtleSEhISE=';
const PRESHARED = 'cHJlc2hhcmVkIGtleSBub3QgZm9yIGFueSBleWVzISE=';

const PLUGIN = 'files/usr/share/rpcd/ucode/wgpathd.uc';

const MAIN = { '.type': 'wgpathd', enabled: '0', role: 'spoke', mesh_iface: 'wg_mesh', hub_iface: 'wg_hub',
	discovery: 'http://10.10.0.1:7780/peers', mode: 'observe' };

const SPOKE_B_SETTINGS = { '.type': 'peer', public_key: SPOKE_B, relay: '10.10.0.12:51820', tunnel: '10.20.0.12' };

// Every secret and address a WireGuard setup keeps in /etc/config/network.
function network() {
	return {
		lan:     { '.type': 'interface', proto: 'static', ipaddr: '192.168.1.1' },
		wg_mesh: { '.type': 'interface', proto: 'wireguard', private_key: PRIVATE, listen_port: '51820',
			addresses: [ '10.20.0.11/24' ] },
		wg_hub:  { '.type': 'interface', proto: 'wireguard', private_key: PRIVATE, addresses: [ '10.10.0.11/24' ] },
		spoke_b: { '.type': 'wireguard_wg_mesh', public_key: SPOKE_B, preshared_key: PRESHARED, description: 'beach',
			allowed_ips: [ '10.20.0.12/32' ], route_allowed_ips: '1', persistent_keepalive: '25' },
		hub: { '.type': 'wireguard_wg_mesh', public_key: HUB, preshared_key: PRESHARED, endpoint_host: '2001:db8::1',
			endpoint_port: '51820', allowed_ips: [ '10.20.0.1/32' ] },
		hub_transit: { '.type': 'wireguard_wg_hub', public_key: HUB, private_key: PRIVATE, endpoint_host: '192.0.2.1' },
	};
}

// The WireGuard interfaces in a zone that rejects input, with the rules a spoke needs.
function firewall() {
	return h.firewall({ '.type': 'defaults', input: 'REJECT' }, h.zone('wan', [ 'wan' ], 'REJECT'),
		h.zone('vpn', [ 'wg_mesh', 'wg_hub' ], 'REJECT'), h.ALLOW_ICMPV6_INPUT, ...h.spoke_rules('vpn'));
}

const FIREWALL_OK = [
	{ level: 'ok', subject: 'firewall', option: 'mesh_iface',
		message: 'firewall: ICMP echo-request (tunnel probe) from wg_mesh (zone vpn): accepted' },
	{ level: 'ok', subject: 'firewall', option: 'hub_iface',
		message: 'firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): accepted' },
	{ level: 'ok', subject: 'firewall', message: 'firewall: ICMPv6 echo-request (underlay probe) from zone wan: accepted' },
];

// The plugin's deps over a committed config the test may change between calls; routes: host -> oif.
function plugin_deps(main, routes) {
	let uci = h.uci({ wgpathd: { main: main ?? MAIN, cfg01a2b3: SPOKE_B_SETTINGS }, network: network(), firewall: firewall() });
	let lookups = [];
	return {
		uci: uci,
		lookups: lookups,
		deps: {
			uci_cursor: uci.cursor,
			fs: h.fs({}),
			route_get: (host) => {
				push(lookups, host);
				return Result.ok({ oif: routes?.[host] ?? 'wg_hub' });
			},
		},
	};
}

// Calls a method the way rpcd does: through the method table, with the request's args.
function call(p, args, method) {
	return rpc.methods(p.deps)[method ?? 'check'].call({ args: args ?? {} });
}

describe('rpc: wgpathd.config methods', () => {
	it('declares check with an optional candidate, peers with an optional iface, and schema', () => {
		let methods = rpc.methods(plugin_deps().deps);
		assert.match([ 'check', 'peers', 'schema' ], keys(methods));
		assert.match([ { candidate: {} }, { iface: '' }, {} ], [ methods.check.args, methods.peers.args, methods.schema.args ]);
	});
});

describe('rpc: wgpathd.config check, committed config', () => {
	it('answers the full check without the interfaces, with machine-usable findings', () => {
		let p = plugin_deps();
		assert.match({ ok: true, findings: [
			{ level: 'ok', subject: 'config', message: 'config: spoke, mode observe, 1 steered peer, 1 not steered' },
			{ level: 'warn', subject: 'config', option: 'enabled', message: "service disabled (option enabled '0'): it will not start" },
			{ level: 'ok', subject: 'peer', section: 'spoke_b', public_key: SPOKE_B,
				message: 'peer spoke_b: relay 10.10.0.12:51820 via wg_hub, probes 10.20.0.12' },
			{ level: 'skip', subject: 'peer', section: 'hub', public_key: HUB,
				message: 'peer hub: not steered (not configured)' },
			...FIREWALL_OK,
		] }, call(p));
		assert.match([ '10.10.0.12', '10.10.0.1' ], p.lookups, 'the relay host, then the discovery host');
	});

	it('reads /etc/config/firewall itself, and gives a missing rule with the rule to add', () => {
		let p = plugin_deps();
		p.uci.data.firewall = h.firewall(h.zone('vpn', [ 'wg_mesh', 'wg_hub' ], 'REJECT'), h.spoke_rules('vpn')[0]);
		let relay = filter(call(p).findings, (f) => f.option == 'hub_iface')[0];
		assert.match({ level: 'warn', subject: 'firewall', option: 'hub_iface',
			message: 'firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): no rule accepts it',
			fix: firewall_fix({ kind: 'relay', proto: 'udp', port: 51820 }, 'vpn') }, relay);
		assert.match([ 'uci add firewall rule', 'config rule' ], [ split(relay.fix.uci, '\n')[0], split(relay.fix.config, '\n')[0] ]);
	});

	it('words each finding as service wgpathd check does', () => {
		let p = plugin_deps();
		let ubus = h.ubus(() => Result.ok({ ...h.status_reply('wg_mesh', { [SPOKE_B]: { hs: 0 } }), ...h.status_reply('wg_hub', {}) }));
		let cli = check.run({ uci: p.uci.cursor(), ubus: ubus, route_get: p.deps.route_get });
		let lines = split(trim(cli.report), '\n');
		let answer = call(p);
		assert.match(filter(lines, (l) => !match(l, /wg_(mesh|hub):/)),
			map(answer.findings, (f) => rtrim(check.render([ f ]), '\n')));
	});

	it('fails with the loader reason and the option it names', () => {
		let p = plugin_deps({ ...MAIN, cycle: 'fast' });
		assert.match({ ok: false, findings: [
			{ level: 'fail', subject: 'config', option: 'cycle', message: 'config: option cycle must be a number from 1 to 10' },
		] }, call(p));
	});

	it('fails a committed interface option in the extended syntax of uci, on its option', () => {
		let p = plugin_deps({ ...MAIN, mesh_iface: '@interface[0]' });
		assert.match({ ok: false, findings: [
			{ level: 'fail', subject: 'config', option: 'mesh_iface',
				message: 'config: option mesh_iface must be an interface name of letters, digits and _' },
		] }, call(p));
	});

	it('reads the configuration afresh on every call', () => {
		let p = plugin_deps();
		call(p);
		p.uci.data.wgpathd.main = { ...MAIN, role: 'relay' };
		assert.match(contains({ ok: false }), call(p));
	});
});

describe('rpc: wgpathd.config check, candidate', () => {
	it('checks unsaved values over the committed config', () => {
		let p = plugin_deps();
		let res = call(p, { candidate: { main: { enabled: '1', mode: 'steer' },
			peers: { [HUB]: { relay: 'hub:51820', tunnel: '10.20.0.1' } } } });
		assert.match({ ok: false, findings: [
			{ level: 'ok', subject: 'config', message: 'config: spoke, mode steer, 1 steered peer, 1 not steered' },
			{ level: 'ok', subject: 'peer', section: 'spoke_b', public_key: SPOKE_B,
				message: 'peer spoke_b: relay 10.10.0.12:51820 via wg_hub, probes 10.20.0.12' },
			{ level: 'fail', subject: 'peer', section: 'hub', public_key: HUB, option: 'relay',
				message: 'peer hub: not steered (invalid relay)' },
			...FIREWALL_OK,
		] }, res);
	});

	it('guards the relay route of a peer the candidate configures', () => {
		let p = plugin_deps(null, { '10.10.0.1': 'wg_mesh' });
		let res = call(p, { candidate: { peers: { [HUB]: { relay: '10.10.0.1:51820', tunnel: '10.20.0.1' } } } });
		assert.match(contains({ level: 'fail', section: 'hub', public_key: HUB, option: 'relay',
			message: 'peer hub: relay routes into wg_mesh' }), filter(res.findings, (f) => f.subject == 'peer')[-1]);
	});

	it('takes a peer cleared of both settings as not configured', () => {
		let p = plugin_deps();
		let res = call(p, { candidate: { peers: { [SPOKE_B]: { relay: '', tunnel: '' } } } });
		assert.match(contains({ level: 'skip', section: 'spoke_b', message: 'peer spoke_b: not steered (not configured)' }),
			res.findings[2]);
	});

	it('writes nothing: the next call without a candidate sees the committed config', () => {
		let p = plugin_deps();
		call(p, { candidate: { main: { role: 'hub' }, peers: { [SPOKE_B]: { relay: '' } } } });
		assert.match({ main: MAIN, cfg01a2b3: SPOKE_B_SETTINGS }, p.uci.data.wgpathd);
		assert.match(contains({ ok: true }), call(p));
	});

	it('answers a malformed candidate with an error and checks nothing', () => {
		let p = plugin_deps();
		assert.match({ error: 'CHECK_INVALID_CANDIDATE', message: "peers: 'spoke_b' is not a WireGuard public key" },
			call(p, { candidate: { peers: { spoke_b: { relay: '' } } } }));
		assert.match({ error: 'CHECK_INVALID_CANDIDATE', message: `peers.${SPOKE_B}: unknown option 'wgpathd_relay'` },
			call(p, { candidate: { peers: { [SPOKE_B]: { wgpathd_relay: '' } } } }));
		assert.match([], p.lookups);
	});

	it('fails an interface option in the extended syntax of uci, instead of looking it up', () => {
		let p = plugin_deps();
		assert.match({ ok: false, findings: [
			{ level: 'fail', subject: 'config', option: 'hub_iface',
				message: 'config: option hub_iface must be an interface name of letters, digits and _' },
		] }, call(p, { candidate: { main: { hub_iface: '@interface[0]' } } }));
	});
});

describe('rpc: wgpathd.config peers', () => {
	const ALLOWED = [ 'section', 'public_key', 'description' ];

	it('lists the peers of the committed mesh interface, and the WireGuard interfaces', () => {
		assert.match({ iface: 'wg_mesh', interfaces: [ 'wg_hub', 'wg_mesh' ], peers: [
			{ section: 'spoke_b', public_key: SPOKE_B, description: 'beach' },
			{ section: 'hub', public_key: HUB },
		] }, call(plugin_deps(), {}, 'peers'));
	});

	it('gives a peer\'s name, key and description only: no key, endpoint or address of network leaves', () => {
		for (let args in [ {}, { iface: 'wg_mesh' }, { iface: 'wg_hub' } ]) {
			let reply = call(plugin_deps(), args, 'peers');
			assert.match([ 'iface', 'interfaces', 'peers' ], keys(reply));
			for (let peer in reply.peers)
				assert.match([], filter(keys(peer), (k) => !(k in ALLOWED)), args);
			for (let secret in [ PRIVATE, PRESHARED, '2001:db8::1', '192.0.2.1', '10.20.0', '51820' ])
				assert.match(-1, index(sprintf('%J', reply), secret), secret);
		}
	});

	it('lists the peers of another WireGuard interface when asked', () => {
		assert.match({ iface: 'wg_hub', interfaces: [ 'wg_hub', 'wg_mesh' ], peers: [ { section: 'hub_transit', public_key: HUB } ] },
			call(plugin_deps(), { iface: 'wg_hub' }, 'peers'));
	});

	it('takes the read interface of a hub', () => {
		let hub = { '.type': 'wgpathd', role: 'hub', read_iface: 'wg_hub', serve_addr: '10.10.0.1', serve_port: '7780' };
		assert.match('wg_hub', call(plugin_deps(hub), {}, 'peers').iface);
	});

	it('lists no peers while no role names a WireGuard interface', () => {
		for (let main in [ { '.type': 'wgpathd' }, { ...MAIN, mesh_iface: 'lan' }, { ...MAIN, mesh_iface: 'wg_nope' } ])
			assert.match({ iface: null, interfaces: [ 'wg_hub', 'wg_mesh' ], peers: [] }, call(plugin_deps(main), {}, 'peers'), main);
	});

	it('refuses an iface that is not a WireGuard interface of network, before any peer is read', () => {
		for (let iface in [ 'lan', 'wg_nope', '@interface[0]', 'wg_mesh.private_key', '' ]) {
			let p = plugin_deps();
			assert.match({ error: 'PEERS_INVALID_IFACE', message: 'iface must name a WireGuard interface of /etc/config/network' },
				call(p, { iface: iface }, 'peers'), iface);
		}
	});
});

describe('rpc: wgpathd.config schema', () => {
	it('gives every timing parameter with its default and bounds, in order', () => {
		let reply = rpc.methods(plugin_deps().deps).schema.call({ args: {} });
		assert.match(keys(params.DEFAULTS), map(reply.parameters, (p) => p.name));
		assert.match({ name: 'cycle', default: 3, min: 1, max: 10, whole: false }, reply.parameters[0]);
		assert.match({ name: 'n_up', default: 5, min: 1, max: 100, whole: true }, reply.parameters[1]);
		for (let p in reply.parameters)
			assert.match([ params.DEFAULTS[p.name], params.BOUNDS[p.name].min, params.BOUNDS[p.name].max ],
				[ p.default, p.min, p.max ], p.name);
	});
});

describe('rpc: the rpcd plugin file', () => {
	it('registers wgpathd.config with its three methods', () => {
		let objects = loadfile(PLUGIN)();
		assert.match([ 'wgpathd.config' ], keys(objects));
		assert.match([ 'check', 'peers', 'schema' ], keys(objects['wgpathd.config']));
		for (let name, method in objects['wgpathd.config'])
			assert.match('function', type(method.call), name);
	});
});
