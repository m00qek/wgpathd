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
		wg_hub:  { '.type': 'interface', proto: 'wireguard' },
		spoke_b: { '.type': 'wireguard_wg_mesh', public_key: SPOKE_B, wgpathd_relay: '10.10.0.12:51820',
			wgpathd_tunnel: '10.20.0.12' },
		hub:  { '.type': 'wireguard_wg_mesh', public_key: HUB },
		...(extra ?? {}),
	};
}

function kernel_of(keys_) {
	let k = {};
	for (let key in keys_)
		k[key] = { hs: 0 };
	return k;
}

// status: the `wireguard status` answer (a reply object or a Result error); routes: host -> oif or false.
function run(main, net, opts) {
	opts ??= {};
	let status = opts.status ?? Result.ok({
		...h.status_reply('wg_mesh', kernel_of([ SPOKE_B, HUB ])),
		...h.status_reply('wg_hub', kernel_of([ HUB ])),
	});
	let routes = opts.routes ?? {};
	let deps = {
		uci: h.uci({ wgpathd: { main: main }, network: net ?? network() }).cursor(),
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
			[ { ...SPOKE, cycle: 'fast' }, 'option cycle must be a positive number' ],
			[ { ...SPOKE, hub_iface: 'wg_nope' }, 'no interface wg_nope in /etc/config/network' ],
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
	it('checks interfaces, relay routes and annotations', () => {
		let res = run(SPOKE);
		assert.match(true, res.ok);
		assert.match(
			'ok    config: spoke, mode steer, 1 steered peer, 1 not steered\n' +
			'ok    wg_mesh: up, 2 peers\n' +
			'ok    wg_hub: up, 1 peer\n' +
			'ok    peer spoke_b: relay 10.10.0.12:51820 via wg_hub, probes 10.20.0.12\n' +
			'skip  peer hub: not steered (missing wgpathd_relay)\n',
			res.report);
	});

	it('fails on a relay routed into the mesh and on a malformed annotation', () => {
		let net = network({ spoke_a: { '.type': 'wireguard_wg_mesh', public_key: SPOKE_A,
			wgpathd_relay: 'not-an-endpoint', wgpathd_tunnel: '10.20.0.11' } });
		let res = run(SPOKE, net, { routes: { '10.10.0.12': 'wg_mesh' } });
		assert.match(false, res.ok);
		assert.match([
			[ 'fail', 'peer spoke_b: relay routes into wg_mesh' ],
			[ 'fail', 'peer spoke_a: not steered (invalid wgpathd_relay)' ],
		], map(filter(res.findings, (f) => f.level == 'fail'), (f) => [ f.level, f.message ]));
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
		assert.match([ 'ok', 'skip', 'ok', 'skip' ], map(res.findings, (f) => f.level));
		assert.match('ubus unavailable: interfaces not checked', res.findings[1].message);
	});

	it('warns that a disabled service will not start', () => {
		let res = run({ ...SPOKE, enabled: '0' });
		assert.match(true, res.ok);
		assert.match("service disabled (option enabled '0'): it will not start", res.findings[1].message);
	});
});

describe('check: full, hub', () => {
	it('checks the read interface', () => {
		let res = run(HUB_MAIN);
		assert.match(true, res.ok);
		assert.match('ok    config: hub, reads wg_mesh, serves 192.0.2.1:7780\nok    wg_mesh: up, 2 peers\n', res.report);
	});

	it('fails without the read interface', () => {
		let res = run(HUB_MAIN, null, { status: Result.ok(h.status_reply('wg_hub', {})) });
		assert.match(false, res.ok);
	});
});
