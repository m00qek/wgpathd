import { describe, it, assert, contains } from 'utest';
import * as h from 'lib.helpers';
import * as rpc from 'wgpathd.rpc';
import * as check from 'wgpathd.check';
import * as Result from 'wgpathd.result';

const SPOKE_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const HUB  = 'W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=';

const PLUGIN = 'files/usr/share/rpcd/ucode/wgpathd.uc';

const MAIN = { '.type': 'wgpathd', enabled: '0', role: 'spoke', mesh_iface: 'wg_mesh', hub_iface: 'wg_hub',
	discovery: 'http://10.10.0.1:7780/peers', mode: 'observe' };

function network() {
	return {
		wg_mesh: { '.type': 'interface', proto: 'wireguard' },
		wg_hub:  { '.type': 'interface', proto: 'wireguard' },
		spoke_b: { '.type': 'wireguard_wg_mesh', public_key: SPOKE_B, wgpathd_relay: '10.10.0.12:51820',
			wgpathd_tunnel: '10.20.0.12' },
		hub: { '.type': 'wireguard_wg_mesh', public_key: HUB },
	};
}

// The plugin's deps over a committed config the test may change between calls; routes: host -> oif.
function plugin_deps(main, routes) {
	let uci = h.uci({ wgpathd: { main: main ?? MAIN }, network: network() });
	let lookups = [];
	return {
		uci: uci,
		lookups: lookups,
		deps: {
			uci_cursor: uci.cursor,
			route_get: (host) => {
				push(lookups, host);
				return Result.ok({ oif: routes?.[host] ?? 'wg_hub' });
			},
		},
	};
}

// Calls `check` the way rpcd does: through the method table, with the request's args.
function call(p, args) {
	return rpc.methods(p.deps).check.call({ args: args ?? {} });
}

describe('rpc: wgpathd.config check, committed config', () => {
	it('declares one method, check, with an optional object argument candidate', () => {
		let methods = rpc.methods(plugin_deps().deps);
		assert.match([ 'check' ], keys(methods));
		assert.match({ candidate: {} }, methods.check.args);
	});

	it('answers the full check without the interfaces, with machine-usable findings', () => {
		let p = plugin_deps();
		assert.match({ ok: true, findings: [
			{ level: 'ok', subject: 'config', message: 'config: spoke, mode observe, 1 steered peer, 1 not steered' },
			{ level: 'warn', subject: 'config', option: 'enabled', message: "service disabled (option enabled '0'): it will not start" },
			{ level: 'ok', subject: 'peer', section: 'spoke_b',
				message: 'peer spoke_b: relay 10.10.0.12:51820 via wg_hub, probes 10.20.0.12' },
			{ level: 'skip', subject: 'peer', section: 'hub', option: 'wgpathd_relay',
				message: 'peer hub: not steered (missing wgpathd_relay)' },
		] }, call(p));
		assert.match([ '10.10.0.12' ], p.lookups);
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
			{ level: 'fail', subject: 'config', option: 'cycle', message: 'config: option cycle must be a positive number' },
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
			peers: { hub: { wgpathd_relay: 'hub:51820', wgpathd_tunnel: '10.20.0.1' } } } });
		assert.match({ ok: false, findings: [
			{ level: 'ok', subject: 'config', message: 'config: spoke, mode steer, 1 steered peer, 1 not steered' },
			{ level: 'ok', subject: 'peer', section: 'spoke_b',
				message: 'peer spoke_b: relay 10.10.0.12:51820 via wg_hub, probes 10.20.0.12' },
			{ level: 'fail', subject: 'peer', section: 'hub', option: 'wgpathd_relay',
				message: 'peer hub: not steered (invalid wgpathd_relay)' },
		] }, res);
	});

	it('guards the relay route of a peer the candidate annotates', () => {
		let p = plugin_deps(null, { '10.10.0.1': 'wg_mesh' });
		let res = call(p, { candidate: { peers: { hub: { wgpathd_relay: '10.10.0.1:51820', wgpathd_tunnel: '10.20.0.1' } } } });
		assert.match(contains({ level: 'fail', section: 'hub', option: 'wgpathd_relay', message: 'peer hub: relay routes into wg_mesh' }),
			res.findings[-1]);
	});

	it('writes nothing: the next call without a candidate sees the committed config', () => {
		let p = plugin_deps();
		call(p, { candidate: { main: { role: 'hub' } } });
		assert.match({ main: MAIN }, p.uci.data.wgpathd);
		assert.match(contains({ ok: true }), call(p));
	});

	it('answers a malformed candidate with an error and checks nothing', () => {
		let p = plugin_deps();
		assert.match({ error: 'CHECK_INVALID_CANDIDATE', message: "no wireguard peer section 'spoke_z' in /etc/config/network" },
			call(p, { candidate: { peers: { spoke_z: { wgpathd_relay: '' } } } }));
		assert.match([], p.lookups);
	});

	it('refuses a peer named in the extended syntax of uci, instead of ignoring it', () => {
		let p = plugin_deps();
		assert.match({ error: 'CHECK_INVALID_CANDIDATE', message: "no wireguard peer section '@wireguard_wg_mesh[0]' in /etc/config/network" },
			call(p, { candidate: { peers: { '@wireguard_wg_mesh[0]': { wgpathd_relay: '10.0.0.1:1' } } } }));
		assert.match({ ok: false, findings: [
			{ level: 'fail', subject: 'config', option: 'hub_iface',
				message: 'config: option hub_iface must be an interface name of letters, digits and _' },
		] }, call(p, { candidate: { main: { hub_iface: '@interface[0]' } } }));
	});
});

describe('rpc: the rpcd plugin file', () => {
	it('registers wgpathd.config with the check method', () => {
		let objects = loadfile(PLUGIN)();
		assert.match([ 'wgpathd.config' ], keys(objects));
		assert.match(contains({ args: { candidate: {} } }), objects['wgpathd.config'].check);
		assert.match('function', type(objects['wgpathd.config'].check.call));
	});
});
