import { describe, it, assert, contains } from 'utest';
import { with_context } from 'context';
import * as h from 'lib.helpers';
import * as daemon from 'wgpathd.daemon';
import * as params from 'wgpathd.params';
import * as Result from 'wgpathd.result';

const SPOKE_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const SPOKE_A = 'ckRTxoRCqAhiHEgHPnhfpN6nU5/F2QmMe0nJ2kt7PFc=';
const HUB  = 'W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=';

const URL          = 'http://10.10.0.1:7780/peers';
const SPOKE_B_RELAY   = '10.10.0.12:51820';
const SPOKE_A_RELAY   = '10.10.0.11:51820';
const SPOKE_B_TUNNEL  = '10.20.0.12';
const SPOKE_A_TUNNEL  = '10.20.0.11';
const SPOKE_B_DIRECT  = '[2001:db8::12]:51820';
const SPOKE_B_ROAMED  = '[2001:db8::99]:51820';
const SPOKE_A_DIRECT  = '[2001:db8::11]:51820';

const SPOKE_B_PEER = { section: 'spoke_b', pubkey: SPOKE_B, relay: SPOKE_B_RELAY, tunnel: SPOKE_B_TUNNEL };
const SPOKE_A_PEER = { section: 'spoke_a', pubkey: SPOKE_A, relay: SPOKE_A_RELAY, tunnel: SPOKE_A_TUNNEL };
const HUB_UNMANAGED = { section: 'hub', pubkey: HUB, reason: 'missing wgpathd_relay' };

function spoke_cfg(extra) {
	return { role: 'spoke', mesh_iface: 'wg_mesh', hub_iface: 'wg_hub', discovery: URL, mode: 'steer',
		overrides: {}, peers: { managed: [ SPOKE_B_PEER ], unmanaged: [ HUB_UNMANAGED ] }, ...(extra ?? {}) };
}

function kernel_of(...keys_) {
	let k = {};
	for (let key in keys_)
		k[key] = { endpoint: null, hs: 0 };
	return k;
}

function payload(peers) {
	let out = {};
	for (let key, direct in peers)
		out[key] = { direct: direct };
	return sprintf('%J', out);
}

function cache_of(peers) {
	return { [daemon.CACHE_PATH]: payload(peers) };
}

function create(w, cfg) {
	cfg ??= spoke_cfg();
	return daemon.create(w.deps, cfg, params.build(cfg));
}

function start(w, cfg) {
	let d = create(w, cfg);
	let res = null;
	d.start((r) => { res = r; });
	assert.match(true, res.ok, 'started');
	return d;
}

// Runs one cycle to completion (the fakes answer at once), then lets `step` seconds pass.
function cycle(w, d, step) {
	let finished = false;
	d.cycle(() => { finished = true; });
	assert.match(true, finished, 'cycle completed');
	w.clock.advance(step ?? 3);
}

function cycles(w, d, n) {
	for (let i = 0; i < n; i++)
		cycle(w, d);
}

function commands_since(w, from) {
	return slice(w.exec.commands(), from);
}

describe('daemon: spoke startup', () => {
	it('refuses to start when the mesh interface is not in the kernel', () => {
		let w = h.world(kernel_of(SPOKE_B), { iface: 'wg_other' });
		let res = null;
		create(w).start((r) => { res = r; });
		assert.match(contains({ ok: false, error: 'INTERFACE_MISSING' }), res);
		assert.match(true, index(res.details, 'no interface wg_mesh') >= 0);
	});

	it('refuses to start when the wireguard status cannot be read', () => {
		let w = h.world(kernel_of(SPOKE_B));
		w.status_ok = false;
		let res = null;
		create(w).start((r) => { res = r; });
		assert.match(contains({ ok: false, error: 'INTERFACE_MISSING' }), res);
	});

	it('leaves a peer whose relay routes into the mesh interface unmanaged', () => {
		let w = h.world(kernel_of(SPOKE_B, SPOKE_A));
		w.routes['10.10.0.12'] = 'wg_mesh';
		let d = start(w, spoke_cfg({ peers: { managed: [ SPOKE_B_PEER, SPOKE_A_PEER ], unmanaged: [] } }));
		cycle(w, d);
		assert.match([ SPOKE_A ], keys(d.status().peers));
		assert.match([ { section: 'spoke_b', pubkey: SPOKE_B, reason: 'relay routes into wg_mesh' } ], d.status().unmanaged);
		assert.match(0, length(filter(w.exec.commands(), (c) => index(c, SPOKE_B) >= 0)));
	});

	it('keeps a peer out of steering while its relay route cannot be looked up', () => {
		let w = h.world(kernel_of(SPOKE_B));
		w.unrouted['10.10.0.12'] = true;
		let d = start(w);
		cycles(w, d, 2);
		assert.match({}, d.status().peers);
		assert.match([ HUB_UNMANAGED, { section: 'spoke_b', pubkey: SPOKE_B,
			reason: 'relay route lookup failed: ROUTE_LOOKUP_FAILED (10.10.0.12: Network unreachable)' } ],
			d.status().unmanaged);
		assert.match([], w.exec.commands());
		assert.match(1, length(w.logs.matching(/section spoke_b unmanaged/)));
	});

	it('manages and steers the peer once a later lookup finds its relay route', () => {
		let w = h.world(kernel_of(SPOKE_B));
		w.unrouted['10.10.0.12'] = true;
		let d = start(w);
		cycle(w, d);
		w.unrouted = {};
		cycle(w, d);
		assert.match(contains({ state: 'RELAY', endpoint: SPOKE_B_RELAY, switches: 0 }), d.status().peers[SPOKE_B]);
		assert.match([ HUB_UNMANAGED ], d.status().unmanaged);
		assert.match([ `wg set wg_mesh peer ${SPOKE_B} endpoint ${SPOKE_B_RELAY}` ], w.exec.commands());
		assert.match([ [ 'info', `peer ${SPOKE_B}: relay route found, now managed` ] ], w.logs.matching(/now managed/));
	});

	it('leaves the peer unmanaged for good once a later lookup routes its relay into the mesh', () => {
		let w = h.world(kernel_of(SPOKE_B));
		w.unrouted['10.10.0.12'] = true;
		let d = start(w);
		cycle(w, d);
		w.unrouted = {};
		w.routes['10.10.0.12'] = 'wg_mesh';
		cycles(w, d, 2);
		w.routes = {};
		cycle(w, d);
		assert.match({}, d.status().peers);
		assert.match([ HUB_UNMANAGED, { section: 'spoke_b', pubkey: SPOKE_B, reason: 'relay routes into wg_mesh' } ],
			d.status().unmanaged);
		assert.match(1, length(w.logs.matching(/section spoke_b unmanaged: relay routes into wg_mesh/)));
	});

	it('logs every unmanaged peer once, by section and reason', () => {
		let w = h.world(kernel_of(SPOKE_B, SPOKE_A));
		w.routes['10.10.0.11'] = 'wg_mesh';
		let d = start(w, spoke_cfg({ peers: { managed: [ SPOKE_B_PEER, SPOKE_A_PEER ], unmanaged: [ HUB_UNMANAGED ] } }));
		cycles(w, d, 3);
		assert.match([
			[ 'info', 'peer section hub unmanaged: missing wgpathd_relay' ],
			[ 'info', 'peer section spoke_a unmanaged: relay routes into wg_mesh' ],
		], w.logs.matching(/unmanaged/));
	});

	it('logs an unknown mode, which runs as observe', () => {
		let w = h.world(kernel_of(SPOKE_B));
		start(w, spoke_cfg({ mode: 'observe', invalid_mode: 'stear' }));
		assert.match([ [ 'warn', "unknown mode 'stear', running in observe mode" ] ], w.logs.matching(/mode/));
	});

	it('logs nothing about the mode when it is valid', () => {
		let w = h.world(kernel_of(SPOKE_B));
		start(w);
		assert.match([], w.logs.matching(/mode/));
	});
});

describe('daemon: spoke cycle, gathering obs', () => {
	it('probes the cache candidate until a fetch succeeds, then the discovered one', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.payload = payload({ [SPOKE_B]: SPOKE_B_ROAMED });
		let d = start(w);
		cycle(w, d);
		assert.match(true, 'ping -6 -c1 -W1 2001:db8::12' in w.exec.commands());
		let seen = length(w.exec.commands());
		cycle(w, d);
		assert.match(true, 'ping -6 -c1 -W1 2001:db8::99' in commands_since(w, seen));
	});

	it('sends no underlay probe for a peer without a candidate', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let d = start(w);
		cycle(w, d);
		assert.match([], filter(w.exec.commands(), (c) => index(c, 'ping -6') == 0));
	});

	it('bounds every probe by tunnel_timeout', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		let d = start(w, spoke_cfg({ overrides: { n_up: 1, tunnel_timeout: 0.5 } }));
		cycle(w, d);
		let pings = filter(w.exec.calls, (c) => c.argv[0] == 'ping');
		assert.match([ 0.5, 0.5 ], map(pings, (c) => c.timeout));
	});

	it('uses a tunnel answer in the next cycle only', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		w.reachable[SPOKE_B_TUNNEL] = true;
		let d = start(w, spoke_cfg({ overrides: { n_up: 1 } }));
		cycles(w, d, 2);
		assert.match('DIRECT', d.status().peers[SPOKE_B].state);

		w.set_code = 1;
		cycle(w, d);
		assert.match(0, d.status().peers[SPOKE_B].down_streak, 'the last answer counts once');
		cycle(w, d);
		assert.match(1, d.status().peers[SPOKE_B].down_streak, 'no probe went out, so no answer');
	});

	it('skips a peer absent from the kernel and logs it once', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let d = start(w, spoke_cfg({ peers: { managed: [ SPOKE_B_PEER, SPOKE_A_PEER ], unmanaged: [] } }));
		cycles(w, d, 3);
		assert.match([ [ 'warn', `peer ${SPOKE_A}: absent from wg_mesh, skipped` ] ], w.logs.matching(/absent/));
		assert.match(0, length(filter(w.exec.commands(), (c) => index(c, SPOKE_A) >= 0)));
		assert.match(3, length(filter(w.exec.commands(), (c) => index(c, SPOKE_B) >= 0)));
	});

	it('decides nothing while the interface cannot be read, logging it once per outage', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let d = start(w);
		w.status_ok = false;
		cycles(w, d, 3);
		assert.match([], w.exec.commands());
		assert.match(3, w.ubus.watchdog_pings());
		w.status_ok = true;
		cycle(w, d);
		assert.match([
			[ 'warn', 'reading wg_mesh failed: UBUS_CALL_FAILED (wireguard status: status 4)' ],
			[ 'info', 'reading wg_mesh recovered' ],
		], w.logs.matching(/reading/));
	});
});

describe('daemon: spoke cycle, applying effects', () => {
	it('runs the underlay probes concurrently', () => {
		let w = h.world(kernel_of(SPOKE_B, SPOKE_A), { deferred: true,
			files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT, [SPOKE_A]: SPOKE_A_DIRECT }) });
		let d = start(w, spoke_cfg({ peers: { managed: [ SPOKE_B_PEER, SPOKE_A_PEER ], unmanaged: [] } }));
		d.cycle(() => {});
		assert.match([ 'ping -6 -c1 -W1 2001:db8::12', 'ping -6 -c1 -W1 2001:db8::11' ], w.exec.commands());
	});

	it('sets each endpoint before sending its tunnel probe', () => {
		let w = h.world(kernel_of(SPOKE_B, SPOKE_A), { deferred: true,
			files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT, [SPOKE_A]: SPOKE_A_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		w.reachable['2001:db8::11'] = true;
		let d = start(w, spoke_cfg({ overrides: { n_up: 1 }, peers: { managed: [ SPOKE_B_PEER, SPOKE_A_PEER ], unmanaged: [] } }));
		let finished = false;
		d.cycle(() => { finished = true; });
		w.exec.flush();
		assert.match([ `wg set wg_mesh peer ${SPOKE_B} endpoint ${SPOKE_B_DIRECT}`, `wg set wg_mesh peer ${SPOKE_A} endpoint ${SPOKE_A_DIRECT}` ],
			commands_since(w, 2));
		w.exec.flush();
		assert.match([ `ping -c1 -W1 ${SPOKE_B_TUNNEL}`, `ping -c1 -W1 ${SPOKE_A_TUNNEL}` ], commands_since(w, 4));
		assert.match(false, finished);
		w.exec.flush();
		assert.match(true, finished);
	});

	it('logs a failed wg set, sends no tunnel probe and completes the cycle', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		w.set_code = 1;
		let d = start(w, spoke_cfg({ overrides: { n_up: 1 } }));
		cycle(w, d);
		assert.match([ [ 'warn', `peer ${SPOKE_B}: setting endpoint ${SPOKE_B_DIRECT} failed: WG_COMMAND_FAILED (exit 1)` ] ],
			w.logs.matching(/setting endpoint/));
		assert.match([], filter(w.exec.commands(), (c) => index(c, 'ping -c1') == 0));
	});

	it('only re-asserts the relay in observe mode', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		w.reachable[SPOKE_B_TUNNEL] = true;
		let d = start(w, spoke_cfg({ mode: 'observe' }));
		cycles(w, d, 8);
		let sets = filter(w.exec.commands(), (c) => index(c, 'wg set') == 0);
		assert.match(8, length(sets));
		assert.match([ `wg set wg_mesh peer ${SPOKE_B} endpoint ${SPOKE_B_RELAY}` ], uniq(sets));
		assert.match([], filter(w.exec.commands(), (c) => index(c, 'ping -c1') == 0));
		assert.match(contains({ state: 'RELAY', ready: true }), d.status().peers[SPOKE_B]);
	});
});

describe('daemon: discovery', () => {
	it('fetches on the first cycle, then every discovery_interval', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		w.payload = payload({ [SPOKE_B]: SPOKE_B_DIRECT });
		let d = start(w, spoke_cfg({ mode: 'observe' }));
		cycles(w, d, 20);
		assert.match([ URL ], w.http.calls, 'nothing asked for a refresh within 60 s');
		cycle(w, d);
		assert.match([ URL, URL ], w.http.calls);
	});

	it('refetches at most every 10 s while a peer asks for a refresh', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let d = start(w);
		cycles(w, d, 9);
		assert.match(3, length(w.http.calls));
	});

	it('replaces the map, saves the cache and marks discovery fresh on success', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.payload = payload({ [SPOKE_B]: SPOKE_B_ROAMED });
		let d = start(w);
		cycle(w, d, 0);
		assert.match({ fresh: true, last_ok: 1790456500 }, d.status().discovery);
		assert.match({ [SPOKE_B]: { direct: SPOKE_B_ROAMED } }, json(w.fs.files[daemon.CACHE_PATH]));
	});

	it('keeps the map, clears fresh and logs the code on failure', () => {
		let w = h.world(kernel_of(SPOKE_B));
		w.payload = payload({ [SPOKE_B]: SPOKE_B_DIRECT });
		let d = start(w);
		cycle(w, d, 60);
		w.payload = null;
		cycle(w, d);
		assert.match({ fresh: false, last_ok: 1790456500 }, d.status().discovery);
		assert.match([ [ 'warn', 'discovery failed: DISCOVERY_FETCH_FAILED (uclient error 4)' ] ], w.logs.matching(/discovery/));
		let seen = length(w.exec.commands());
		cycle(w, d);
		assert.match(true, 'ping -6 -c1 -W1 2001:db8::12' in commands_since(w, seen));
	});

	it('treats an HTTP error or an invalid payload as a failed fetch', () => {
		let w = h.world(kernel_of(SPOKE_B));
		w.payload = payload({ [SPOKE_B]: SPOKE_B_DIRECT });
		w.http_status = 500;
		let d = start(w);
		cycle(w, d, 60);
		w.http_status = 200;
		w.payload = '{ not json';
		cycle(w, d);
		assert.match([
			[ 'warn', 'discovery failed: DISCOVERY_FETCH_FAILED (HTTP 500)' ],
			[ 'warn', 'discovery failed: DISCOVERY_INVALID_JSON' ],
		], w.logs.matching(/discovery/));
		assert.match(false, d.status().discovery.fresh);
		assert.match(false, exists(w.fs.files, daemon.CACHE_PATH));
	});
});

describe('daemon: discovery never blocks the cycle', () => {
	it('keeps the cadence and the watchdog while a fetch hangs, and never overlaps fetches', () => {
		let w = h.world(kernel_of(SPOKE_B), { http_deferred: true });
		w.payload = payload({ [SPOKE_B]: SPOKE_B_DIRECT });
		let d = start(w);
		cycles(w, d, 6);
		assert.match(6, w.ubus.watchdog_pings());
		assert.match([ URL ], w.http.calls);
		assert.match(6, length(filter(w.exec.commands(), (c) => index(c, 'wg set') == 0)));
	});

	it('applies a late answer whenever it arrives, then fetches again when due', () => {
		let w = h.world(kernel_of(SPOKE_B), { http_deferred: true });
		w.payload = payload({ [SPOKE_B]: SPOKE_B_DIRECT });
		let d = start(w);
		cycles(w, d, 4);
		w.http.flush();
		assert.match(true, d.status().discovery.fresh);
		let seen = length(w.exec.commands());
		cycle(w, d);
		assert.match(true, 'ping -6 -c1 -W1 2001:db8::12' in commands_since(w, seen));
		assert.match([ URL, URL ], w.http.calls, 'the next fetch counts from the last attempt');
	});
});

describe('daemon: watchdog', () => {
	it('pings once per completed cycle, with the exact payload', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let d = start(w);
		assert.match(0, w.ubus.watchdog_pings(), 'not at startup');
		cycles(w, d, 3);
		let pings = filter(w.ubus.calls, (c) => c.obj == 'service');
		assert.match([ h.WATCHDOG_PING, h.WATCHDOG_PING, h.WATCHDOG_PING ], pings);
	});

	it('does not ping before the cycle has completed', () => {
		let w = h.world(kernel_of(SPOKE_B), { deferred: true });
		let d = start(w);
		d.cycle(() => {});
		assert.match(0, w.ubus.watchdog_pings());
		w.exec.flush();
		assert.match(1, w.ubus.watchdog_pings());
	});

	it('logs a failed ping and still completes the cycle', () => {
		let w = h.world(kernel_of(SPOKE_B));
		w.watchdog = Result.err('UBUS_CALL_FAILED', 'Not found');
		let d = start(w);
		cycle(w, d);
		assert.match([ [ 'warn', 'watchdog ping failed: UBUS_CALL_FAILED (Not found)' ] ], w.logs.matching(/watchdog/));
	});
});

describe('daemon: status', () => {
	it('reports every managed peer in RELAY before the first cycle', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let d = start(w);
		assert.match({
			role: 'spoke', mode: 'steer', discovery: { fresh: false, last_ok: null },
			peers: { [SPOKE_B]: { state: 'RELAY', endpoint: null, target: null, up_streak: 0, down_streak: 0,
				backoff: 0, ready: false, switches: 0, last_change: null } },
			unmanaged: [ HUB_UNMANAGED ],
		}, d.status());
	});

	it('reports the endpoint set and the metric of the last cycle', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		let d = start(w);
		cycles(w, d, 2);
		assert.match({ state: 'RELAY', endpoint: SPOKE_B_RELAY, target: null, up_streak: 2, down_streak: 0,
			backoff: 0, ready: false, switches: 0, last_change: null }, d.status().peers[SPOKE_B]);
	});
});

describe('daemon: scenario through the real decide', () => {
	it('goes RELAY -> TRIALING -> DIRECT, follows a roam, and is demoted back to RELAY', () => {
		let w = h.world({ [SPOKE_B]: { endpoint: SPOKE_B_RELAY, hs: 1790456000 } },
			{ files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		let d = start(w);
		let peer = () => d.status().peers[SPOKE_B];

		cycles(w, d, 4);
		assert.match(contains({ state: 'RELAY', up_streak: 4, endpoint: SPOKE_B_RELAY }), peer());
		assert.match(SPOKE_B_RELAY, w.kernel[SPOKE_B].endpoint);

		w.reachable[SPOKE_B_TUNNEL] = true;
		cycle(w, d);
		assert.match(contains({ state: 'TRIALING', endpoint: SPOKE_B_DIRECT, target: SPOKE_B_DIRECT, switches: 1 }), peer());
		assert.match(SPOKE_B_DIRECT, w.kernel[SPOKE_B].endpoint);

		cycle(w, d);
		assert.match(contains({ state: 'DIRECT', endpoint: SPOKE_B_DIRECT, switches: 2 }), peer());

		w.kernel[SPOKE_B].endpoint = SPOKE_B_ROAMED;
		cycle(w, d);
		assert.match(contains({ state: 'DIRECT', endpoint: SPOKE_B_ROAMED, target: SPOKE_B_ROAMED, switches: 2 }), peer());
		assert.match(1, length(w.logs.matching(/roam DIRECT -> DIRECT \(roam_adopted\)/)));

		w.reachable[SPOKE_B_TUNNEL] = false;
		cycle(w, d);
		assert.match(contains({ state: 'DIRECT', down_streak: 0 }), peer(), 'the last probe was answered');
		cycle(w, d);
		assert.match(contains({ state: 'DIRECT', down_streak: 1 }), peer());
		let demoted_at = w.clock.wall();
		cycle(w, d);
		assert.match({ state: 'RELAY', endpoint: SPOKE_B_RELAY, target: null, up_streak: 0, down_streak: 0,
			backoff: 30, ready: false, switches: 3,
			last_change: { ts: demoted_at, from: 'DIRECT', to: 'RELAY', reason: 'demoted' } }, peer());
		assert.match(SPOKE_B_RELAY, w.kernel[SPOKE_B].endpoint);
		assert.match([
			[ 'info', `peer ${SPOKE_B}: transition RELAY -> TRIALING (trial_start)` ],
			[ 'info', `peer ${SPOKE_B}: transition TRIALING -> DIRECT (trial_ok)` ],
			[ 'info', `peer ${SPOKE_B}: transition DIRECT -> RELAY (demoted)` ],
		], w.logs.matching(/transition/));
	});
});

describe('daemon: hub', () => {
	const HUB_CFG = { role: 'hub', read_iface: 'wg_mesh', serve_addr: '10.10.0.1', serve_port: '7780', overrides: {} };

	it('snapshots the v6 endpoints of the read interface at startup', () => {
		let w = h.world({ [SPOKE_B]: { endpoint: SPOKE_B_DIRECT, hs: 1790456491 }, [SPOKE_A]: { endpoint: SPOKE_A_RELAY, hs: 0 } });
		let d = start(w, HUB_CFG);
		assert.match({ role: 'hub', peers: { [SPOKE_B]: { direct: SPOKE_B_DIRECT, handshake_age: 9 } } }, d.status());
	});

	it('refuses to start without the read interface', () => {
		let w = h.world(kernel_of(SPOKE_B), { iface: 'wg_other' });
		let res = null;
		create(w, HUB_CFG).start((r) => { res = r; });
		assert.match(contains({ ok: false, error: 'INTERFACE_MISSING' }), res);
	});

	it('refreshes the snapshot every cycle and pings the watchdog', () => {
		let w = h.world({ [SPOKE_B]: { endpoint: SPOKE_B_DIRECT, hs: 1790456491 } });
		let d = start(w, HUB_CFG);
		w.kernel[SPOKE_B].endpoint = SPOKE_B_ROAMED;
		cycle(w, d);
		assert.match({ [SPOKE_B]: { direct: SPOKE_B_ROAMED, handshake_age: 9 } }, d.status().peers);
		assert.match([ h.WATCHDOG_PING ], filter(w.ubus.calls, (c) => c.obj == 'service'));
	});

	it('keeps the last snapshot while the interface cannot be read', () => {
		let w = h.world({ [SPOKE_B]: { endpoint: SPOKE_B_DIRECT, hs: 1790456491 } });
		let d = start(w, HUB_CFG);
		w.status_ok = false;
		cycles(w, d, 2);
		assert.match({ [SPOKE_B]: { direct: SPOKE_B_DIRECT, handshake_age: 9 } }, d.status().peers);
		assert.match(1, length(w.logs.matching(/reading wg_mesh failed/)));
	});
});

describe('daemon: run', () => {
	const MAIN = { '.type': 'wgpathd', role: 'spoke', mesh_iface: 'wg_mesh', hub_iface: 'wg_hub', discovery: URL,
		mode: 'steer', cycle: '0.5' };
	const NETWORK = {
		wg_mesh: { '.type': 'interface', proto: 'wireguard' },
		wg_hub:  { '.type': 'interface', proto: 'wireguard' },
		spoke_b:    { '.type': 'wireguard_wg_mesh', public_key: SPOKE_B, wgpathd_relay: SPOKE_B_RELAY, wgpathd_tunnel: SPOKE_B_TUNNEL },
	};

	function run(w, main) {
		let code = null;
		let loop = h.uloop();
		with_context({ uci: { data: { wgpathd: { main: main }, network: NETWORK } } }, (ctx) => {
			code = daemon.run({ ...w.deps, uci: ctx.uci, uloop: loop });
		});
		return { code: code, loop: loop };
	}

	it('publishes status on ubus, runs a first cycle and arms the next one', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let r = run(w, MAIN);
		assert.match(0, r.code);
		assert.match(true, r.loop.ran);
		assert.match(contains({ role: 'spoke', mode: 'steer' }), w.ubus.published.wgpathd.status.call());
		assert.match(1, w.ubus.watchdog_pings());
		assert.match([ 0, 500 ], map(r.loop.timers, (t) => t.ms));
		r.loop.timers[1].cb();
		assert.match(2, w.ubus.watchdog_pings());
		assert.match([ 0, 500, 500 ], map(r.loop.timers, (t) => t.ms));
	});

	it('exits 1 with a logged reason on an invalid configuration', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let r = run(w, { ...MAIN, role: 'relay' });
		assert.match(1, r.code);
		assert.match(false, r.loop.ran);
		assert.match([ [ 'error', 'invalid configuration: CONFIG_INVALID_ROLE (relay)' ] ], w.logs.entries);
		assert.match([ 'invalid configuration: CONFIG_INVALID_ROLE (relay)' ], w.stderr);
	});

	it('exits 1 with a logged reason when startup fails', () => {
		let w = h.world(kernel_of(SPOKE_B), { iface: 'wg_other' });
		let r = run(w, MAIN);
		assert.match(1, r.code);
		assert.match(true, r.loop.ended);
		assert.match({}, w.ubus.published);
		assert.match(1, length(w.logs.matching(/^startup failed: INTERFACE_MISSING/)));
		assert.match(1, length(filter(w.stderr, (m) => index(m, 'startup failed: INTERFACE_MISSING') == 0)));
	});
});
