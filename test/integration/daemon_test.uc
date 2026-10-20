import { describe, it, assert, contains } from 'utest';
import * as h from 'lib.helpers';
import * as daemon from 'wgpathd.daemon';
import * as params from 'wgpathd.params';
import * as Result from 'wgpathd.result';
import { readfile, lsdir } from 'fs';

const SPOKE_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const SPOKE_A = 'ckRTxoRCqAhiHEgHPnhfpN6nU5/F2QmMe0nJ2kt7PFc=';
const HUB  = 'W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=';
const SPOKE_C = 'hQrcvDZE8wGkiQzp3/zDaTL3dY0PfbFTcQ4r3sG1UUk=';

const URL          = 'http://10.10.0.1:7780/peers';
const SPOKE_B_RELAY   = '10.10.0.12:51820';
const SPOKE_A_RELAY   = '10.10.0.11:51820';
const SPOKE_B_TUNNEL  = '10.20.0.12';
const SPOKE_A_TUNNEL  = '10.20.0.11';
const SPOKE_B_DIRECT  = '[2001:db8::12]:51820';
const SPOKE_B_ROAMED  = '[2001:db8::99]:51820';
const SPOKE_A_DIRECT  = '[2001:db8::11]:51820';
const SPOKE_C_RELAY   = '10.10.0.13:51820';
const SPOKE_C_TUNNEL  = '10.20.0.13';
const SPOKE_C_DIRECT  = '[2001:db8::13]:51820';

const B   = 'peer spoke_b (O0LYRo/R)';
const A   = 'peer spoke_a (ckRTxoRC)';
const HUB_NAME = 'peer hub (W+1CXUTT)';

const SPOKE_B_PEER = { section: 'spoke_b', pubkey: SPOKE_B, relay: SPOKE_B_RELAY, tunnel: SPOKE_B_TUNNEL };
const SPOKE_A_PEER = { section: 'spoke_a', pubkey: SPOKE_A, relay: SPOKE_A_RELAY, tunnel: SPOKE_A_TUNNEL };
const SPOKE_C_PEER = { section: 'spoke_c', pubkey: SPOKE_C, relay: SPOKE_C_RELAY, tunnel: SPOKE_C_TUNNEL };
const HUB_UNMANAGED = { section: 'hub', pubkey: HUB, reason: 'not configured' };

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

function probed_since(w, from) {
	return slice(w.icmp.hosts(), from);
}

function trio_states(d) {
	return map([ SPOKE_B, SPOKE_A, SPOKE_C ], (k) => [ d.status().peers[k].state, d.status().peers[k].down_streak ]);
}

// spoke-b alone, DIRECT on a path that answers; `cfg` is its configuration.
function direct_one(overrides) {
	let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
	w.reachable['2001:db8::12'] = true;
	w.reachable[SPOKE_B_TUNNEL] = true;
	let cfg = spoke_cfg({ overrides: { n_up: 1, ...(overrides ?? {}) } });
	let d = start(w, cfg);
	cycles(w, d, 2);
	assert.match(contains({ state: 'DIRECT', down_streak: 0 }), d.status().peers[SPOKE_B]);
	return { w: w, d: d, cfg: cfg };
}

// Three peers, all DIRECT on paths that answer.
function direct_trio(overrides) {
	let w = h.world(kernel_of(SPOKE_B, SPOKE_A, SPOKE_C),
		{ files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT, [SPOKE_A]: SPOKE_A_DIRECT, [SPOKE_C]: SPOKE_C_DIRECT }) });
	for (let host in [ '2001:db8::12', '2001:db8::11', '2001:db8::13', SPOKE_B_TUNNEL, SPOKE_A_TUNNEL, SPOKE_C_TUNNEL ])
		w.reachable[host] = true;
	let d = start(w, spoke_cfg({ overrides: { n_up: 1, ...(overrides ?? {}) },
		peers: { managed: [ SPOKE_B_PEER, SPOKE_A_PEER, SPOKE_C_PEER ], unmanaged: [] } }));
	cycles(w, d, 2);
	assert.match([ [ 'DIRECT', 0 ], [ 'DIRECT', 0 ], [ 'DIRECT', 0 ] ], trio_states(d));
	return { w: w, d: d };
}

function set_all(...pairs) {
	let argv = [ 'wg set wg_mesh' ];
	for (let i = 0; i < length(pairs); i += 2)
		push(argv, `peer ${pairs[i]} endpoint ${pairs[i + 1]}`);
	return join(' ', argv);
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
		assert.match([ [ 'info', `${B}: unmanaged reason=relay route lookup failed: ROUTE_LOOKUP_FAILED (10.10.0.12: Network unreachable)` ] ],
			w.logs.matching(/^peer spoke_b .*unmanaged/));
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
		assert.match([ set_all(SPOKE_B, SPOKE_B_RELAY) ], w.exec.commands());
		assert.match([ [ 'notice', `${B}: relay route found, now managed` ] ], w.logs.matching(/now managed/));
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
		assert.match([ [ 'warning', `${B}: unmanaged reason=relay routes into wg_mesh` ] ],
			w.logs.matching(/unmanaged reason=relay routes/));
	});

	it('logs every unmanaged peer once, by section, key prefix and reason', () => {
		let w = h.world(kernel_of(SPOKE_B, SPOKE_A));
		w.routes['10.10.0.11'] = 'wg_mesh';
		let d = start(w, spoke_cfg({ peers: { managed: [ SPOKE_B_PEER, SPOKE_A_PEER ], unmanaged: [ HUB_UNMANAGED ] } }));
		cycles(w, d, 3);
		assert.match([
			[ 'warning', `${HUB_NAME}: unmanaged reason=not configured` ],
			[ 'warning', `${A}: unmanaged reason=relay routes into wg_mesh` ],
		], w.logs.matching(/unmanaged/));
	});

	it('logs an unknown mode, which runs as observe', () => {
		let w = h.world(kernel_of(SPOKE_B));
		start(w, spoke_cfg({ mode: 'observe', invalid_mode: 'stear' }));
		assert.match([ [ 'warning', 'unknown mode, running in observe mode value=stear' ] ], w.logs.matching(/mode/));
	});

	it('names a peer without a valid key by its section alone', () => {
		let w = h.world(kernel_of(SPOKE_B));
		start(w, spoke_cfg({ peers: { managed: [ SPOKE_B_PEER ], unmanaged: [ { section: 'bad', pubkey: null, reason: 'invalid public_key' } ] } }));
		assert.match([ [ 'warning', 'peer bad: unmanaged reason=invalid public_key' ] ], w.logs.matching(/unmanaged/));
	});

	it('logs how many peers the discovery cache held', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		start(w);
		assert.match([ [ 'info', 'discovery cache: loaded peers=1' ] ], w.logs.matching(/cache/));
		w = h.world(kernel_of(SPOKE_B));
		start(w);
		assert.match([ [ 'info', 'discovery cache: none usable' ] ], w.logs.matching(/cache/));
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
		assert.match([ '2001:db8::12' ], w.icmp.hosts());
		cycle(w, d);
		assert.match([ '2001:db8::99' ], probed_since(w, 1));
	});

	it('sends no underlay probe for a peer without a candidate', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let d = start(w);
		cycle(w, d);
		assert.match([], w.icmp.sent);
	});

	it('sends a small underlay probe by the routes, and a full-size tunnel probe bound to the mesh', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		let d = start(w, spoke_cfg({ overrides: { n_up: 1 } }));
		cycle(w, d);
		assert.match([
			{ host: '2001:db8::12', size: 16, device: null, timeout: 1 },
			{ host: SPOKE_B_TUNNEL, size: 1360 - 20 - 8, device: 'wg_mesh', timeout: 1 },
		], w.icmp.sent);
	});

	it('sizes a tunnel probe to the MTU the mesh has now, for either address family', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		let peer = { ...SPOKE_B_PEER, tunnel: 'fd00:2::12' };
		let d = start(w, spoke_cfg({ overrides: { n_up: 1, trial_window: 20 }, peers: { managed: [ peer ], unmanaged: [] } }));
		cycle(w, d);
		w.mtu = 1420;
		cycle(w, d);
		assert.match([ [ 'fd00:2::12', 1360 - 40 - 8 ], [ 'fd00:2::12', 1420 - 40 - 8 ] ],
			map(slice(w.icmp.sent, 1), (p) => [ p.host, p.size ]));
	});

	it('waits tunnel_timeout for every probe, to the fraction of a second', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		let d = start(w, spoke_cfg({ overrides: { n_up: 1, tunnel_timeout: 0.35 } }));
		cycle(w, d);
		assert.match([ 0.35, 0.35 ], map(w.icmp.sent, (p) => p.timeout));
	});

	it('probes the underlay only while the peer is in RELAY, observe mode included', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		w.reachable[SPOKE_B_TUNNEL] = true;
		let cfg = spoke_cfg({ overrides: { n_up: 1 } });
		let d = start(w, cfg);
		let underlay = () => length(filter(w.icmp.hosts(), (host) => host == '2001:db8::12'));
		cycle(w, d);
		assert.match('TRIALING', d.status().peers[SPOKE_B].state);
		cycles(w, d, 3);
		assert.match('DIRECT', d.status().peers[SPOKE_B].state);
		assert.match(1, underlay(), 'none while TRIALING or DIRECT');

		cfg = { ...cfg, mode: 'observe' };
		d.reload(cfg, params.build(cfg));
		cycle(w, d);
		assert.match(1, underlay(), 'the cycle that returns to RELAY starts in DIRECT');
		cycles(w, d, 3);
		assert.match(4, underlay());
	});

	it('uses a tunnel answer in the next cycle only', () => {
		let t = direct_one();
		let w = t.w, d = t.d;
		w.set_code = 1;
		cycle(w, d);
		assert.match(0, d.status().peers[SPOKE_B].down_streak, 'the last answer counts once');
		cycle(w, d);
		assert.match(1, d.status().peers[SPOKE_B].down_streak, 'no probe went out, so no answer');
	});

	it('judges a tunnel answer by the endpoint the kernel holds right after it', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		w.reachable[SPOKE_B_TUNNEL] = true;
		let d = start(w, spoke_cfg({ overrides: { n_up: 1, trial_window: 20 } }));
		w.on_probe = (p) => {
			if (p.host == SPOKE_B_TUNNEL)
				w.kernel[SPOKE_B].endpoint = SPOKE_B_RELAY;
		};
		cycles(w, d, 2);
		assert.match(contains({ state: 'TRIALING', relayed_answers: 2 }), d.status().peers[SPOKE_B], 'answered over the relay');

		w.on_probe = null;
		cycle(w, d);
		w.kernel[SPOKE_B].endpoint = SPOKE_B_RELAY;
		cycle(w, d);
		assert.match(contains({ state: 'DIRECT', relayed_answers: 2 }), d.status().peers[SPOKE_B],
			'answered direct, whatever came over the relay later');
	});

	it('skips a peer absent from the kernel and logs it once', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let d = start(w, spoke_cfg({ peers: { managed: [ SPOKE_B_PEER, SPOKE_A_PEER ], unmanaged: [] } }));
		cycles(w, d, 3);
		assert.match([ [ 'warning', `${A}: absent from wg_mesh, skipped` ] ], w.logs.matching(/absent/));
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
			[ 'warning', 'reading wg_mesh failed: UBUS_CALL_FAILED (wireguard status: status 4)' ],
			[ 'notice', 'reading wg_mesh recovered' ],
		], w.logs.matching(/reading/));
	});

	it('logs a peer that comes back into the kernel, and steers it again', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let d = start(w, spoke_cfg({ peers: { managed: [ SPOKE_B_PEER, SPOKE_A_PEER ], unmanaged: [] } }));
		cycles(w, d, 2);
		w.kernel[SPOKE_A] = { endpoint: null, hs: 0 };
		cycles(w, d, 2);
		assert.match([
			[ 'warning', `${A}: absent from wg_mesh, skipped` ],
			[ 'notice', `${A}: back in wg_mesh` ],
		], w.logs.matching(/absent|back in/));
		assert.match(2, length(filter(w.exec.commands(), (c) => index(c, SPOKE_A) >= 0)));
	});
});

// A candidate the hub published that this router must not take (finding F6 of the
// 2026-09-29 audit): probing or trialing it would loop into the tunnels or stay on the router.
describe('daemon: refused candidates', () => {
	const OWN = '2001:db8::1';

	function refused_world(direct) {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: direct }) });
		w.payload = payload({ [SPOKE_B]: direct });
		w.local[OWN] = true;
		w.routes['fd00:20::12'] = 'wg_mesh';
		w.routes['fd00:30::12'] = 'wg_hub';
		for (let host in [ OWN, 'fd00:20::12', 'fd00:30::12', 'fd00:2::12', '2001:db8:ffff::12' ])
			w.reachable[host] = true;
		w.reachable[SPOKE_B_TUNNEL] = true;
		w.reachable['fd00:2::12'] = true;
		return w;
	}

	let cases = [
		[ `[${OWN}]:51820`, SPOKE_B_PEER, 'own address' ],
		[ '[fd00:20::12]:51820', SPOKE_B_PEER, 'routes into wg_mesh' ],
		[ '[fd00:30::12]:51820', SPOKE_B_PEER, 'routes into wg_hub' ],
		[ '[fd00:2::12]:51820', { ...SPOKE_B_PEER, tunnel: 'fd00:2::12' }, 'tunnel address' ],
		[ '[2001:db8:ffff::12]:1', { ...SPOKE_B_PEER, relay: '[2001:db8:ffff::12]:51820' }, 'relay address' ],
	];

	it('never probes, trials or sets one, and says why in the status', () => {
		for (let c in cases) {
			let w = refused_world(c[0]);
			let d = start(w, spoke_cfg({ overrides: { n_up: 1 }, peers: { managed: [ c[1] ], unmanaged: [] } }));
			cycles(w, d, 6);
			let host = substr(split(c[0], ']')[0], 1);
			assert.match([], filter(w.icmp.hosts(), (x) => x == host), c[2]);
			assert.match([ 'RELAY', c[1].relay ], [ d.status().peers[SPOKE_B].state, w.kernel[SPOKE_B].endpoint ], c[2]);
			assert.match({ candidate: c[0], candidate_refused: c[2] }, {
				candidate: d.status().peers[SPOKE_B].candidate, candidate_refused: d.status().peers[SPOKE_B].candidate_refused }, c[2]);
		}
	});

	it('logs a refusal once while it lasts, and its end', () => {
		let w = refused_world('[fd00:20::12]:51820');
		let d = start(w, spoke_cfg({ overrides: { n_up: 1 } }));
		cycles(w, d, 4);
		delete w.routes['fd00:20::12'];
		cycles(w, d, 2);
		assert.match([
			[ 'warning', `${B}: candidate refused endpoint=[fd00:20::12]:51820 reason=routes into wg_mesh` ],
			[ 'notice', `${B}: candidate no longer refused` ],
		], w.logs.matching(/candidate/));
		assert.match([ 'DIRECT', null ], [ d.status().peers[SPOKE_B].state, d.status().peers[SPOKE_B].candidate_refused ]);
	});

	it('logs a new refusal when the reason changes', () => {
		let w = refused_world('[fd00:20::12]:51820');
		let d = start(w);
		cycle(w, d);
		w.routes['fd00:20::12'] = 'wg_hub';
		cycles(w, d, 2);
		assert.match([ 'reason=routes into wg_mesh', 'reason=routes into wg_hub' ],
			map(w.logs.matching(/candidate refused/), (e) => match(e[1], /reason=.*$/)[0]));
	});

	it('leaves an authenticated roam to a refused address to decide', () => {
		let w = refused_world('[fd00:20::12]:51820');
		let d = start(w, spoke_cfg({ overrides: { n_up: 1 } }));
		cycle(w, d);
		w.kernel[SPOKE_B].endpoint = SPOKE_B_ROAMED;
		w.reachable['2001:db8::99'] = true;
		cycles(w, d, 3);
		assert.match('DIRECT', d.status().peers[SPOKE_B].state);
		assert.match(SPOKE_B_ROAMED, w.kernel[SPOKE_B].endpoint);
	});

	it('takes a peer\'s candidate beside another peer\'s refused one', () => {
		let w = refused_world('[fd00:20::12]:51820');
		w.kernel[SPOKE_A] = { endpoint: null, hs: 0 };
		w.payload = payload({ [SPOKE_B]: '[fd00:20::12]:51820', [SPOKE_A]: SPOKE_A_DIRECT });
		w.reachable['2001:db8::11'] = true;
		w.reachable[SPOKE_A_TUNNEL] = true;
		let d = start(w, spoke_cfg({ overrides: { n_up: 1 }, peers: { managed: [ SPOKE_B_PEER, SPOKE_A_PEER ], unmanaged: [] } }));
		cycles(w, d, 5);
		assert.match([ 'RELAY', 'DIRECT' ], [ d.status().peers[SPOKE_B].state, d.status().peers[SPOKE_A].state ]);
	});
});

describe('daemon: spoke cycle, applying effects', () => {
	it('reads the kernel once the underlay probes are in, so a roam during them is seen', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		let d = start(w);
		cycle(w, d);
		w.icmp.deferred = true;
		let reads = w.ubus.status_reads();
		let finished = false;
		d.cycle(() => { finished = true; });
		assert.match(reads, w.ubus.status_reads(), 'not while the probe waits');
		w.kernel[SPOKE_B].endpoint = SPOKE_B_ROAMED;
		w.icmp.flush();
		assert.match(contains({ state: 'TRIALING', target: SPOKE_B_ROAMED }), d.status().peers[SPOKE_B]);
		w.icmp.flush();
		assert.match(true, finished);
	});

	it('sends the underlay probes together, and sets nothing before they are all in', () => {
		let w = h.world(kernel_of(SPOKE_B, SPOKE_A), { deferred: true,
			files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT, [SPOKE_A]: SPOKE_A_DIRECT }) });
		let d = start(w, spoke_cfg({ peers: { managed: [ SPOKE_B_PEER, SPOKE_A_PEER ], unmanaged: [] } }));
		d.cycle(() => {});
		assert.match([ '2001:db8::12', '2001:db8::11' ], w.icmp.hosts());
		assert.match([], w.exec.commands());
		w.icmp.flush();
		assert.match(1, length(w.exec.commands()));
	});

	it('sets every endpoint in one wg set, then sends the tunnel probes', () => {
		let w = h.world(kernel_of(SPOKE_B, SPOKE_A), { deferred: true,
			files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT, [SPOKE_A]: SPOKE_A_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		w.reachable['2001:db8::11'] = true;
		let d = start(w, spoke_cfg({ overrides: { n_up: 1 }, peers: { managed: [ SPOKE_B_PEER, SPOKE_A_PEER ], unmanaged: [] } }));
		let finished = false;
		d.cycle(() => { finished = true; });
		w.icmp.flush();
		assert.match([ set_all(SPOKE_B, SPOKE_B_DIRECT, SPOKE_A, SPOKE_A_DIRECT) ], w.exec.commands());
		assert.match([], probed_since(w, 2), 'no tunnel probe before the endpoints are set');
		w.exec.flush();
		assert.match([ SPOKE_B_TUNNEL, SPOKE_A_TUNNEL ], probed_since(w, 2));
		assert.match(false, finished);
		w.icmp.flush();
		assert.match(true, finished);
	});

	it('runs no command at all while no peer is decided', () => {
		let w = h.world(kernel_of(SPOKE_A));
		let d = start(w);
		cycles(w, d, 2);
		assert.match([], w.exec.commands());
		assert.match(2, w.ubus.watchdog_pings());
	});

	it('logs a failed wg set, sends no tunnel probe and completes the cycle', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		w.set_code = 1;
		let d = start(w, spoke_cfg({ overrides: { n_up: 1 } }));
		cycle(w, d);
		assert.match([ [ 'warning', 'setting endpoints on wg_mesh failed: WG_COMMAND_FAILED (exit 1)' ] ],
			w.logs.matching(/setting endpoints/));
		assert.match([ '2001:db8::12' ], w.icmp.hosts());
		assert.match(1, w.ubus.watchdog_pings());
	});

	it('probes no peer after a failed wg set, and every peer once the next one works', () => {
		let t = direct_trio({ m_down: 3 });
		let w = t.w, d = t.d;
		w.set_code = 1;
		let seen = length(w.icmp.sent);
		cycle(w, d);
		assert.match([], probed_since(w, seen));
		w.set_code = 0;
		cycle(w, d);
		assert.match([ [ 'DIRECT', 1 ], [ 'DIRECT', 1 ], [ 'DIRECT', 1 ] ], trio_states(d), 'no probe went out, so no answer');
		assert.match([ SPOKE_B_TUNNEL, SPOKE_A_TUNNEL, SPOKE_C_TUNNEL ], probed_since(w, seen));
		assert.match(set_all(SPOKE_B, SPOKE_B_DIRECT, SPOKE_A, SPOKE_A_DIRECT, SPOKE_C, SPOKE_C_DIRECT), w.exec.commands()[-1]);
		cycle(w, d);
		assert.match([ [ 'DIRECT', 0 ], [ 'DIRECT', 0 ], [ 'DIRECT', 0 ] ], trio_states(d));
	});

	it('logs a failing wg set once per outage, then its recovery', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.set_code = 1;
		let d = start(w, spoke_cfg());
		for (let i = 0; i < 4; i++)
			cycle(w, d);
		w.set_code = 0;
		cycle(w, d);
		cycle(w, d);
		assert.match([
			[ 'warning', 'setting endpoints on wg_mesh failed: WG_COMMAND_FAILED (exit 1)' ],
			[ 'notice', 'setting endpoints on wg_mesh recovered' ],
		], w.logs.matching(/setting endpoints/));
	});

	it('demotes a direct path that drops full-size packets, though small ones cross', () => {
		let t = direct_one();
		let w = t.w, d = t.d;
		w.max_size = 1200;
		cycles(w, d, 3);
		assert.match(contains({ state: 'RELAY', last_change: contains({ reason: 'demoted' }) }), d.status().peers[SPOKE_B]);
	});

	it('probes nothing through the mesh while its MTU cannot be read, and logs it once per outage', () => {
		let t = direct_one({ m_down: 4 });
		let w = t.w, d = t.d;
		w.mtu = null;
		let seen = length(w.icmp.sent);
		cycles(w, d, 3);
		assert.match([], probed_since(w, seen));
		assert.match(contains({ state: 'DIRECT', down_streak: 2 }), d.status().peers[SPOKE_B]);
		w.mtu = 1360;
		cycles(w, d, 2);
		assert.match(contains({ state: 'DIRECT', down_streak: 0 }), d.status().peers[SPOKE_B]);
		assert.match([
			[ 'warning', 'reading the MTU of wg_mesh failed: LINK_LOOKUP_FAILED (wg_mesh: interface not found)' ],
			[ 'notice', 'reading the MTU of wg_mesh recovered' ],
		], w.logs.matching(/MTU/));
	});

	it('counts a probe that could not be sent as unanswered, and logs it once per outage', () => {
		let t = direct_one({ m_down: 3 });
		let w = t.w, d = t.d;
		w.send_error[SPOKE_B_TUNNEL] = 'Message too large';
		cycles(w, d, 3);
		assert.match(contains({ state: 'DIRECT', down_streak: 2 }), d.status().peers[SPOKE_B]);
		w.send_error = {};
		cycles(w, d, 2);
		assert.match([
			[ 'warning', `sending probes failed: PROBE_SEND_FAILED (${SPOKE_B_TUNNEL}: Message too large)` ],
			[ 'notice', 'sending probes recovered' ],
		], w.logs.matching(/sending probes/));
	});

	it('reports the first probe of a cycle that could not be sent', () => {
		let t = direct_trio({ m_down: 3 });
		let w = t.w, d = t.d;
		w.send_error[SPOKE_B_TUNNEL] = 'No such device';
		w.send_error[SPOKE_C_TUNNEL] = 'Message too large';
		cycle(w, d);
		assert.match([ [ 'warning', `sending probes failed: PROBE_SEND_FAILED (${SPOKE_B_TUNNEL}: No such device)` ] ],
			w.logs.matching(/sending probes/));
	});

	it('takes a cycle that sends no probe as no news about sending them', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		w.payload = payload({});
		w.send_error[SPOKE_B_TUNNEL] = 'No such device';
		let d = start(w, spoke_cfg({ overrides: { n_up: 1, trial_window: 2 } }));
		cycles(w, d, 3);
		assert.match(contains({ state: 'RELAY', last_change: contains({ reason: 'trial_timeout' }) }), d.status().peers[SPOKE_B]);
		let seen = length(w.icmp.sent);
		cycles(w, d, 3);
		assert.match([], probed_since(w, seen), 'discovery took the candidate away');
		assert.match([ [ 'warning', `sending probes failed: PROBE_SEND_FAILED (${SPOKE_B_TUNNEL}: No such device)` ] ],
			w.logs.matching(/sending probes/), 'no probe went out, so no recovery either');
	});

	it('reads the endpoints at once after an answer, and once for all the answers that came meanwhile', () => {
		let t = direct_trio();
		let w = t.w, d = t.d;
		w.icmp.deferred = true;
		w.ubus.deferred = true;
		let finished = false;
		d.cycle(() => { finished = true; });
		w.ubus.flush();
		let reads = w.ubus.status_reads();
		assert.match(3, w.icmp.flush(), 'three answers arrive together');
		assert.match(reads + 1, w.ubus.status_reads(), 'the first answer is read at once');
		w.ubus.flush();
		assert.match(reads + 2, w.ubus.status_reads(), 'the other two share the next read');
		assert.match(false, finished);
		w.ubus.flush();
		assert.match(true, finished);
		assert.match(reads + 2, w.ubus.status_reads());

		w.icmp.deferred = false;
		w.ubus.deferred = false;
		cycle(w, d);
		assert.match([ [ 'DIRECT', 0 ], [ 'DIRECT', 0 ], [ 'DIRECT', 0 ] ], trio_states(d));
	});

	it('reads the endpoints after an answer only', () => {
		let t = direct_one({ m_down: 3 });
		let w = t.w, d = t.d;
		w.reachable[SPOKE_B_TUNNEL] = false;
		let reads = w.ubus.status_reads();
		cycle(w, d);
		assert.match(reads + 1, w.ubus.status_reads(), 'the gather read alone');
		w.reachable[SPOKE_B_TUNNEL] = true;
		cycle(w, d);
		assert.match(reads + 3, w.ubus.status_reads(), 'the gather read and the one after the answer');
	});

	it('takes an answer whose endpoint could not be read afterwards as no proof', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		w.reachable[SPOKE_B_TUNNEL] = true;
		w.answer_read_ok = false;
		let d = start(w, spoke_cfg({ overrides: { n_up: 1, trial_window: 20, m_down: 3 } }));
		cycles(w, d, 3);
		assert.match(contains({ state: 'TRIALING', target: SPOKE_B_DIRECT }), d.status().peers[SPOKE_B], 'answered, never read');
		assert.match([], w.logs.matching(/reading wg_mesh/), 'the gather reads all worked');
		w.answer_read_ok = true;
		cycles(w, d, 2);
		assert.match('DIRECT', d.status().peers[SPOKE_B].state);
		w.answer_read_ok = false;
		cycles(w, d, 3);
		assert.match(contains({ state: 'DIRECT', down_streak: 0 }), d.status().peers[SPOKE_B], 'DIRECT holds on any answer');
	});

	it('judges each answer by a read made after it arrived', () => {
		let t = direct_trio();
		let w = t.w, d = t.d;
		w.icmp.deferred = true;
		w.ubus.deferred = true;
		w.on_probe = (p) => {
			if (p.host == SPOKE_A_TUNNEL)
				w.kernel[SPOKE_A].endpoint = SPOKE_A_RELAY;
		};
		let finished = false;
		d.cycle(() => { finished = true; });
		w.ubus.flush();
		w.icmp.flush();
		w.ubus.flush();
		w.ubus.flush();
		assert.match(true, finished);

		w.icmp.deferred = false;
		w.ubus.deferred = false;
		w.on_probe = null;
		cycle(w, d);
		assert.match([ 0, 1, 0 ], map([ SPOKE_B, SPOKE_A, SPOKE_C ], (k) => d.status().peers[k].relayed_answers),
			'spoke-a answered over the relay after the first read was made');
	});

	it('only re-asserts the relay in observe mode', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		w.reachable[SPOKE_B_TUNNEL] = true;
		let d = start(w, spoke_cfg({ mode: 'observe' }));
		cycles(w, d, 8);
		let sets = filter(w.exec.commands(), (c) => index(c, 'wg set') == 0);
		assert.match(8, length(sets));
		assert.match([ set_all(SPOKE_B, SPOKE_B_RELAY) ], uniq(sets));
		assert.match([ '2001:db8::12' ], uniq(w.icmp.hosts()), 'underlay probes only');
		assert.match(8, length(w.icmp.sent));
		assert.match(contains({ state: 'RELAY', ready: true }), d.status().peers[SPOKE_B]);
	});

	it('logs in observe mode when a peer becomes ready for a trial, and when it has gone n_up cycles without evidence', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		let cfg = spoke_cfg({ mode: 'observe' });
		let d = start(w, cfg);
		cycles(w, d, 8);
		w.reachable['2001:db8::12'] = false;
		cycles(w, d, params.build(cfg).n_up);
		assert.match(false, d.status().peers[SPOKE_B].ready);
		assert.match([ [ 'notice', `${B}: ready, steer would trial endpoint=${SPOKE_B_DIRECT}` ] ], w.logs.matching(/ready/));
		cycle(w, d);
		assert.match([
			[ 'notice', `${B}: ready, steer would trial endpoint=${SPOKE_B_DIRECT}` ],
			[ 'info', `${B}: no longer ready` ],
		], w.logs.matching(/ready/));
	});

	it('logs a roam as the endpoint observe mode is ready to trial, once while roams keep coming', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		let d = start(w, spoke_cfg({ mode: 'observe', overrides: { n_up: 2 } }));
		cycle(w, d);
		for (let i = 0; i < 6; i++) {
			if (i % 2 == 0)
				w.kernel[SPOKE_B].endpoint = SPOKE_B_ROAMED;
			cycle(w, d);
			assert.match(i % 2 == 0, d.status().peers[SPOKE_B].ready);
		}
		assert.match([ [ 'notice', `${B}: ready, steer would trial endpoint=${SPOKE_B_ROAMED}` ] ], w.logs.matching(/ready/));
		cycles(w, d, 2);
		assert.match([ [ 'info', `${B}: no longer ready` ] ], w.logs.matching(/no longer/));
	});

	it('forces a steered peer back to the relay when the mode turns to observe, with its own reason', () => {
		let t = direct_one();
		let w = t.w, d = t.d;
		let cfg = { ...t.cfg, mode: 'observe' };
		d.reload(cfg, params.build(cfg));
		cycle(w, d);
		assert.match(contains({ state: 'RELAY', last_change: contains({ reason: 'observe_mode' }) }), d.status().peers[SPOKE_B]);
		assert.match([ [ 'notice', `${B}: transition DIRECT -> RELAY reason=observe_mode endpoint=${SPOKE_B_RELAY}` ] ],
			w.logs.matching(/-> RELAY/));
	});

	it('logs a trial timeout with the backoff it starts', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		let d = start(w, spoke_cfg({ overrides: { n_up: 1 } }));
		cycles(w, d, 5);
		assert.match([
			[ 'notice', `${B}: transition RELAY -> TRIALING reason=trial_start endpoint=${SPOKE_B_DIRECT}` ],
			[ 'notice', `${B}: transition TRIALING -> RELAY reason=trial_timeout backoff=30s endpoint=${SPOKE_B_RELAY}` ],
		], w.logs.matching(/transition/));
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
		assert.match({ fresh: true, last_ok: 1790456500, url: URL }, d.status().discovery);
		assert.match({ [SPOKE_B]: { direct: SPOKE_B_ROAMED } }, json(w.fs.files[daemon.CACHE_PATH]));
	});

	it('keeps the map, clears fresh and logs the code on failure', () => {
		let w = h.world(kernel_of(SPOKE_B));
		w.payload = payload({ [SPOKE_B]: SPOKE_B_DIRECT });
		let d = start(w);
		cycle(w, d, 60);
		w.payload = null;
		cycle(w, d);
		assert.match({ fresh: false, last_ok: 1790456500, url: URL }, d.status().discovery);
		assert.match([ [ 'warning', 'discovery failed: DISCOVERY_FETCH_FAILED (uclient error 4)' ] ], w.logs.matching(/^discovery failed/));
		let seen = length(w.icmp.sent);
		cycle(w, d);
		assert.match([ '2001:db8::12' ], probed_since(w, seen));
	});

	it('treats an HTTP error or an invalid payload as a failed fetch', () => {
		for (let bad in [ { status: 500, body: payload({ [SPOKE_B]: SPOKE_B_DIRECT }), log: 'DISCOVERY_FETCH_FAILED (HTTP 500)' },
		                  { status: 200, body: '{ not json', log: 'DISCOVERY_INVALID_JSON' } ]) {
			let w = h.world(kernel_of(SPOKE_B));
			w.http_status = bad.status;
			w.payload = bad.body;
			let d = start(w);
			cycle(w, d);
			assert.match([ [ 'warning', `discovery failed: ${bad.log}` ] ], w.logs.matching(/^discovery failed/));
			assert.match(false, d.status().discovery.fresh);
			assert.match(false, exists(w.fs.files, daemon.CACHE_PATH));
		}
	});

	it('logs a failing discovery once per outage, and the recovery', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let d = start(w);
		cycles(w, d, 12);
		assert.match(3, length(w.http.calls), 'retried every 10 s');
		w.payload = payload({ [SPOKE_B]: SPOKE_B_DIRECT });
		cycles(w, d, 4);
		assert.match([
			[ 'warning', 'discovery failed: DISCOVERY_FETCH_FAILED (uclient error 4)' ],
			[ 'notice', 'discovery recovered' ],
		], w.logs.matching(/^discovery (failed|recovered)/));
	});

	it('logs a failing cache save once per outage, and the recovery', () => {
		let w = h.world(kernel_of(SPOKE_B));
		w.payload = payload({ [SPOKE_B]: SPOKE_B_DIRECT });
		let open = w.fs.open;
		w.fs.open = () => null;
		let d = start(w);
		cycle(w, d, 60);
		cycle(w, d, 60);
		assert.match(true, d.status().discovery.fresh, 'the payload is used all the same');
		w.fs.open = open;
		cycle(w, d, 60);
		cycle(w, d, 60);
		assert.match([
			[ 'warning', `saving the discovery cache failed: CACHE_SAVE_FAILED (${daemon.CACHE_PATH}: ${daemon.CACHE_PATH}.tmp: Operation not permitted)` ],
			[ 'notice', 'saving the discovery cache recovered' ],
		], w.logs.matching(/saving/));
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
		let seen = length(w.icmp.sent);
		cycle(w, d);
		assert.match([ '2001:db8::12' ], probed_since(w, seen));
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
		assert.match([ [ 'warning', 'watchdog ping failed: UBUS_CALL_FAILED (Not found)' ] ], w.logs.matching(/watchdog/));
	});

	it('logs a failing ping once per outage, and the recovery', () => {
		let w = h.world(kernel_of(SPOKE_B));
		w.watchdog = Result.err('UBUS_CALL_FAILED', 'Not found');
		let d = start(w);
		cycles(w, d, 3);
		w.watchdog = Result.ok(null);
		cycles(w, d, 2);
		assert.match([
			[ 'warning', 'watchdog ping failed: UBUS_CALL_FAILED (Not found)' ],
			[ 'notice', 'watchdog ping recovered' ],
		], w.logs.matching(/watchdog/));
	});
});

const TIMING = { cycle: 3, n_up: 5, m_down: 2, tunnel_timeout: 1, trial_window: 8, backoff_min: 30,
	backoff_max: 900, backoff_reset: 600, discovery_interval: 60, give_up_after: 3, give_up_pause: 21600 };

// A trial on spoke-b that times out: its direct path answers the underlay echo but not the tunnel probe.
function failed_trial(cfg_extra) {
	let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
	w.reachable['2001:db8::12'] = true;
	let d = start(w, spoke_cfg({ overrides: { n_up: 1, trial_window: 6 }, ...(cfg_extra ?? {}) }));
	return { w: w, d: d, peer: () => d.status().peers[SPOKE_B] };
}

describe('daemon: status', () => {
	it('reports every managed peer in RELAY before the first cycle', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let d = start(w);
		assert.match({
			role: 'spoke', mode: 'steer', now: 1790456500, mesh_iface: 'wg_mesh', hub_iface: 'wg_hub', params: TIMING,
			discovery: { fresh: false, last_ok: null, url: URL },
			peers: { [SPOKE_B]: { state: 'RELAY', section: 'spoke_b', endpoint: null, target: null, candidate: null, candidate_refused: null,
				last_target: null, since: 1790456500, trial_deadline: null, next_trial: null, up_streak: 0, down_streak: 0,
				failed_target: null, failed_trials: 0, given_up: null,
				backoff: 0, ready: false, switches: 0, relayed_answers: 0, last_change: null } },
			unmanaged: [ HUB_UNMANAGED ],
			history: [],
		}, d.status());
	});

	it('reports the endpoint set and the metric of the last cycle', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		let d = start(w);
		cycles(w, d, 2);
		assert.match({ state: 'RELAY', section: 'spoke_b', endpoint: SPOKE_B_RELAY, target: null, candidate: SPOKE_B_DIRECT, candidate_refused: null,
			last_target: null, since: 1790456500, trial_deadline: null, next_trial: null, up_streak: 2, down_streak: 0,
			failed_target: null, failed_trials: 0, given_up: null,
			backoff: 0, ready: false, switches: 0, relayed_answers: 0, last_change: null }, d.status().peers[SPOKE_B]);
	});

	it('reports the timing parameters in effect, overrides included', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let d = start(w, spoke_cfg({ overrides: { m_down: 3, cycle: 0.5 } }));
		assert.match({ ...TIMING, m_down: 3, cycle: 0.5 }, d.status().params);
	});

	it('shows the discovery url without the credentials of its user:pass@ part', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let d = start(w, spoke_cfg({ discovery: 'http://wgpathd:secret@10.10.0.1:7780/peers' }));
		assert.match('http://10.10.0.1:7780/peers', d.status().discovery.url);
	});

	it('times a trial: since it began and when it ends, in wall-clock seconds', () => {
		let t = failed_trial();
		cycle(t.w, t.d, 2);
		let started = 1790456500;
		assert.match(contains({ state: 'TRIALING', target: SPOKE_B_DIRECT, last_target: SPOKE_B_DIRECT, since: started,
			trial_deadline: started + 6, next_trial: null }), t.peer());
		assert.match(t.w.clock.wall(), t.d.status().now);
	});

	it('after a failed trial, keeps the endpoint tried and says when the next trial may start', () => {
		let t = failed_trial();
		cycles(t.w, t.d, 3);
		let fell_back = t.w.clock.wall() - 3;
		assert.match(contains({ state: 'RELAY', target: null, last_target: SPOKE_B_DIRECT, candidate: SPOKE_B_DIRECT,
			since: fell_back, trial_deadline: null, next_trial: fell_back + 30, backoff: 30,
			last_change: { ts: fell_back, from: 'TRIALING', to: 'RELAY', reason: 'trial_timeout' } }), t.peer());
	});

	it('clears next_trial once the backoff has run out', () => {
		let t = failed_trial();
		cycles(t.w, t.d, 3);
		t.w.clock.advance(27);
		assert.match(contains({ state: 'RELAY', next_trial: null }), t.peer());
	});

	it('never shows a next trial in observe mode, where none starts', () => {
		let t = failed_trial();
		cycles(t.w, t.d, 3);
		t.d.reload(spoke_cfg({ mode: 'observe' }), params.build(spoke_cfg({ mode: 'observe', overrides: { n_up: 1 } })));
		assert.match(contains({ state: 'RELAY', next_trial: null }), t.peer());
	});

	it('keeps the time a peer became managed as its since until its first change', () => {
		let w = h.world(kernel_of(SPOKE_B));
		w.unrouted['10.10.0.12'] = true;
		let d = start(w);
		cycle(w, d);
		w.unrouted = {};
		cycle(w, d);
		cycle(w, d);
		assert.match(contains({ state: 'RELAY', since: 1790456503 }), d.status().peers[SPOKE_B]);
	});
});

describe('daemon: status history', () => {
	it('lists the transitions and roams across peers, newest first', () => {
		let w = h.world({ [SPOKE_B]: { endpoint: SPOKE_B_RELAY, hs: 0 }, [SPOKE_A]: { endpoint: SPOKE_A_RELAY, hs: 0 } },
			{ files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT, [SPOKE_A]: SPOKE_A_DIRECT }) });
		for (let host in [ '2001:db8::12', '2001:db8::11', SPOKE_B_TUNNEL ])
			w.reachable[host] = true;
		let d = start(w, spoke_cfg({ overrides: { n_up: 1, trial_window: 6 },
			peers: { managed: [ SPOKE_B_PEER, SPOKE_A_PEER ], unmanaged: [] } }));
		let t0 = w.clock.wall();
		cycles(w, d, 2);
		w.kernel[SPOKE_B].endpoint = SPOKE_B_ROAMED;
		cycles(w, d, 2);
		assert.match([
			{ ts: t0 + 6, section: 'spoke_a', pubkey: SPOKE_A, from: 'TRIALING', to: 'RELAY', reason: 'trial_timeout',
				endpoint: SPOKE_A_RELAY },
			{ ts: t0 + 6, section: 'spoke_b', pubkey: SPOKE_B, from: 'DIRECT', to: 'DIRECT', reason: 'roam_adopted',
				endpoint: SPOKE_B_ROAMED },
			{ ts: t0 + 3, section: 'spoke_b', pubkey: SPOKE_B, from: 'TRIALING', to: 'DIRECT', reason: 'trial_ok',
				endpoint: SPOKE_B_DIRECT },
			{ ts: t0, section: 'spoke_a', pubkey: SPOKE_A, from: 'RELAY', to: 'TRIALING', reason: 'trial_start',
				endpoint: SPOKE_A_DIRECT },
			{ ts: t0, section: 'spoke_b', pubkey: SPOKE_B, from: 'RELAY', to: 'TRIALING', reason: 'trial_start',
				endpoint: SPOKE_B_DIRECT },
		], d.status().history);
	});

	it('keeps the last 20 changes only', () => {
		let w = h.world(kernel_of(SPOKE_B), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		let d = start(w, spoke_cfg({ overrides: { n_up: 1, trial_window: 1, backoff_min: 1, backoff_max: 1, give_up_after: 100 } }));
		cycles(w, d, 30);
		let history = d.status().history;
		assert.match(20, length(history));
		assert.match(w.clock.wall() - 3, history[0].ts, 'the newest first');
		assert.match(true, d.status().peers[SPOKE_B].switches > 20);
	});

	it('keeps the entries of a peer a reload removed', () => {
		let t = failed_trial();
		cycle(t.w, t.d);
		t.d.reload(spoke_cfg({ peers: { managed: [], unmanaged: [] } }), params.build(spoke_cfg()));
		assert.match({}, t.d.status().peers);
		assert.match([ contains({ section: 'spoke_b', reason: 'trial_start' }) ], t.d.status().history);
	});
});

describe('daemon: giving up a direct address', () => {
	const FAST = { n_up: 1, trial_window: 6, backoff_min: 1, backoff_max: 1, give_up_after: 2, give_up_pause: 60 };

	// spoke-b's direct address answers the echo but not the tunnel probe, until it is given up.
	function given_up(extra) {
		let t = failed_trial({ overrides: { ...FAST, ...(extra ?? {}) } });
		for (let i = 0; i < 20 && t.peer().given_up == null; i++)
			cycle(t.w, t.d);
		assert.match('object', type(t.peer().given_up), 'given up');
		return t;
	}

	let last_logs = (t, re, n) => slice(t.w.logs.matching(re), -n);

	it('logs the give-up after the timeout that causes it, and shows it in the status', () => {
		let t = given_up();
		let at = t.w.clock.wall() - 3;
		assert.match([
			[ 'notice', `${B}: transition TRIALING -> RELAY reason=trial_timeout backoff=1s endpoint=${SPOKE_B_RELAY}` ],
			[ 'notice', `${B}: direct address given up endpoint=${SPOKE_B_DIRECT} failed_trials=2 pause=60s` ],
		], last_logs(t, /transition|given up/, 2));
		assert.match(1, length(t.w.logs.matching(/given up/)));
		assert.match(contains({ state: 'RELAY', endpoint: SPOKE_B_RELAY, last_target: SPOKE_B_DIRECT, failed_target: SPOKE_B_DIRECT,
			failed_trials: 2, given_up: { since: at, until: at + 60 }, ready: false }), t.peer());
		assert.match([ 'trial_timeout', 'trial_start' ], map(slice(t.d.status().history, 0, 2), (e) => e.reason),
			'the give-up is no path change');
	});

	it('counts a failed trial before it gives the address up', () => {
		let t = failed_trial({ overrides: FAST });
		cycles(t.w, t.d, 3);
		assert.match(contains({ state: 'RELAY', failed_target: SPOKE_B_DIRECT, failed_trials: 1, given_up: null }), t.peer());
	});

	it('sets only the relay and sends only the underlay probe while the address is given up', () => {
		let t = given_up();
		let seen = length(t.w.exec.commands());
		let probed = length(t.w.icmp.sent);
		cycles(t.w, t.d, 15);
		assert.match([ set_all(SPOKE_B, SPOKE_B_RELAY) ], uniq(filter(commands_since(t.w, seen), (c) => index(c, 'wg set') == 0)));
		assert.match([ '2001:db8::12' ], uniq(probed_since(t.w, probed)));
		assert.match(contains({ state: 'RELAY', ready: false, up_streak: 15 }), t.peer());
		assert.match([], t.w.logs.matching(/resumed/));
	});

	it('tries once more after the pause, and gives the address up again at once when that fails', () => {
		let t = given_up();
		t.w.clock.advance(60);
		cycle(t.w, t.d);
		assert.match([
			[ 'notice', `${B}: direct address trials resumed reason=pause_over endpoint=${SPOKE_B_DIRECT}` ],
			[ 'notice', `${B}: transition RELAY -> TRIALING reason=trial_start endpoint=${SPOKE_B_DIRECT}` ],
		], last_logs(t, /resumed|transition/, 2));
		assert.match(contains({ state: 'TRIALING', failed_trials: 2, given_up: null }), t.peer());
		cycles(t.w, t.d, 2);
		assert.match([ 'notice', `${B}: direct address given up endpoint=${SPOKE_B_DIRECT} failed_trials=3 pause=60s` ],
			t.w.logs.entries[-1]);
	});

	it('trials a roam at once, and says why', () => {
		let t = given_up();
		t.w.kernel[SPOKE_B].endpoint = SPOKE_B_ROAMED;
		cycle(t.w, t.d);
		assert.match([
			[ 'notice', `${B}: direct address trials resumed reason=roam endpoint=${SPOKE_B_DIRECT}` ],
			[ 'notice', `${B}: transition RELAY -> TRIALING reason=trial_start endpoint=${SPOKE_B_ROAMED}` ],
		], last_logs(t, /resumed|transition/, 2));
	});

	it('trials another address the hub publishes, and says why', () => {
		let t = given_up({ give_up_pause: 3600 });
		t.w.payload = payload({ [SPOKE_B]: SPOKE_B_ROAMED });
		t.w.reachable['2001:db8::99'] = true;
		t.w.clock.advance(60);
		for (let i = 0; i < 3 && t.peer().state == 'RELAY'; i++)
			cycle(t.w, t.d);
		assert.match([
			[ 'notice', `${B}: direct address trials resumed reason=new_candidate endpoint=${SPOKE_B_DIRECT}` ],
			[ 'notice', `${B}: transition RELAY -> TRIALING reason=trial_start endpoint=${SPOKE_B_ROAMED}` ],
		], last_logs(t, /resumed|transition/, 2));
	});

	it('keeps the give-up of a peer a reload keeps, and forgets it for a peer the reload changes', () => {
		let t = given_up({ give_up_pause: 3600 });
		let since = t.peer().given_up.since;
		let cfg = spoke_cfg({ overrides: { ...FAST, give_up_pause: 7200 } });
		t.d.reload(cfg, params.build(cfg));
		assert.match(contains({ failed_trials: 2, given_up: { since: since, until: since + 7200 } }), t.peer());
		cycles(t.w, t.d, 3);
		assert.match(contains({ state: 'RELAY', ready: false }), t.peer());

		let changed = spoke_cfg({ overrides: FAST, peers: { managed: [ { ...SPOKE_B_PEER, tunnel: '10.20.0.99' } ], unmanaged: [] } });
		t.d.reload(changed, params.build(changed));
		assert.match(contains({ failed_target: null, failed_trials: 0, given_up: null }), t.peer());
	});

	it('does not call a given-up peer ready in observe mode', () => {
		let t = given_up({ give_up_pause: 3600 });
		let cfg = spoke_cfg({ mode: 'observe', overrides: { ...FAST, give_up_pause: 3600 } });
		t.d.reload(cfg, params.build(cfg));
		cycles(t.w, t.d, 5);
		assert.match(contains({ state: 'RELAY', ready: false }), t.peer());
		assert.match([], t.w.logs.matching(/ready/));
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
		assert.match([ [ 'notice', `${B}: roamed endpoint=${SPOKE_B_ROAMED}` ] ], w.logs.matching(/roamed/));

		w.reachable[SPOKE_B_TUNNEL] = false;
		cycle(w, d);
		assert.match(contains({ state: 'DIRECT', down_streak: 0 }), peer(), 'the last probe was answered');
		cycle(w, d);
		assert.match(contains({ state: 'DIRECT', down_streak: 1 }), peer());
		let demoted_at = w.clock.wall();
		cycle(w, d);
		assert.match({ state: 'RELAY', section: 'spoke_b', endpoint: SPOKE_B_RELAY, target: null, candidate: SPOKE_B_DIRECT, candidate_refused: null,
			last_target: SPOKE_B_ROAMED, since: demoted_at, trial_deadline: null, next_trial: demoted_at + 30,
			failed_target: null, failed_trials: 0, given_up: null,
			up_streak: 0, down_streak: 0, backoff: 30, ready: false, switches: 3, relayed_answers: 0,
			last_change: { ts: demoted_at, from: 'DIRECT', to: 'RELAY', reason: 'demoted' } }, peer());
		assert.match(SPOKE_B_RELAY, w.kernel[SPOKE_B].endpoint);
		assert.match([
			[ 'notice', `${B}: transition RELAY -> TRIALING reason=trial_start endpoint=${SPOKE_B_DIRECT}` ],
			[ 'notice', `${B}: transition TRIALING -> DIRECT reason=trial_ok endpoint=${SPOKE_B_DIRECT}` ],
			[ 'notice', `${B}: transition DIRECT -> RELAY reason=demoted failed_probes=2 backoff=30s endpoint=${SPOKE_B_RELAY}` ],
		], w.logs.matching(/transition/));
		assert.match([], w.logs.matching(/ready/), 'steer mode says it with the transitions');
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

const MAIN = { '.type': 'wgpathd', role: 'spoke', mesh_iface: 'wg_mesh', hub_iface: 'wg_hub', discovery: URL,
	mode: 'steer', cycle: '1.5' };

// Each peer in /etc/config/network, with its settings in a `peer` section of
// /etc/config/wgpathd; `extra`: more network sections.
function substrate(peers, extra) {
	let conf = { network: { wg_mesh: { '.type': 'interface', proto: 'wireguard' },
		wg_hub: { '.type': 'interface', proto: 'wireguard' }, ...(extra ?? {}) }, peers: {} };
	for (let i = 0; i < length(peers); i++) {
		let p = peers[i];
		conf.network[p.section] = { '.type': 'wireguard_wg_mesh', public_key: p.pubkey };
		conf.peers[`cfg0${i}a2b3`] = { '.type': 'peer', public_key: p.pubkey, relay: p.relay, tunnel: p.tunnel };
	}
	return conf;
}

function uci_data(main, conf) {
	return { wgpathd: { main: main, ...conf.peers }, network: conf.network };
}

function run(w, main, conf, loop) {
	let uci = h.uci(uci_data(main, conf ?? substrate([ SPOKE_B_PEER ])));
	loop ??= h.uloop();
	let code = daemon.run({ ...w.deps, uci_cursor: uci.cursor, uloop: loop });
	return { code: code, loop: loop, uci: uci, status: () => w.ubus.published.wgpathd.status.call() };
}

// Fires the most recently armed timer: the next cycle.
function tick(r) {
	r.loop.timers[-1].cb();
}

function reload(r, main, conf) {
	r.uci.data = uci_data(main, conf);
	r.loop.signals.SIGHUP();
}

// netifd creates the interface again on ifup, and it starts on the endpoint of its
// configuration: here a stale one, as when the peer's address changed since.
describe('daemon: a mesh interface created again', () => {
	const STALE = '[2001:db8::77]:51820';

	function recreated_direct(how) {
		let r = direct_one();
		if (how == 'gone') {
			r.w.status_ok = false;
			cycle(r.w, r.d);
		}
		else {
			r.w.ifindex = 4;
		}
		r.w.kernel[SPOKE_B].endpoint = STALE;
		r.w.status_ok = true;
		cycle(r.w, r.d);
		return r;
	}

	for (let how in [ 'gone', 'new index' ]) {
		it(`keeps DIRECT on its target and asserts it again, after the interface was ${how}`, () => {
			let r = recreated_direct(how);
			assert.match([ 'DIRECT', SPOKE_B_DIRECT ], [ r.d.status().peers[SPOKE_B].state, r.w.kernel[SPOKE_B].endpoint ]);
			assert.match([], r.w.logs.matching(/roamed/));
			assert.match(1, length(r.w.logs.matching((how == 'gone') ? /wg_mesh may have been created again/ : /wg_mesh was created again/)));
			cycles(r.w, r.d, 3);
			assert.match([ 'DIRECT', 0 ], [ r.d.status().peers[SPOKE_B].state, r.d.status().peers[SPOKE_B].down_streak ]);
		});
	}

	it('still takes a roam on the interface once it is back', () => {
		let r = recreated_direct('gone');
		r.w.kernel[SPOKE_B].endpoint = SPOKE_B_ROAMED;
		r.w.reachable['2001:db8::99'] = true;
		cycle(r.w, r.d);
		assert.match([ 'DIRECT', SPOKE_B_ROAMED ], [ r.d.status().peers[SPOKE_B].state, r.w.kernel[SPOKE_B].endpoint ]);
		assert.match(1, length(r.w.logs.matching(/roamed/)));
	});
});

describe('daemon: run', () => {
	it('publishes status on ubus, runs a first cycle and arms the next one', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let r = run(w, MAIN);
		assert.match(0, r.code);
		assert.match(true, r.loop.ran);
		assert.match(contains({ role: 'spoke', mode: 'steer' }), r.status());
		assert.match(1, w.ubus.watchdog_pings());
		assert.match([ 0, 1500 ], map(r.loop.timers, (t) => t.ms));
		tick(r);
		assert.match(2, w.ubus.watchdog_pings());
		assert.match([ 0, 1500, 1500 ], map(r.loop.timers, (t) => t.ms));
	});

	// uloop keeps a timer that has fired until it is cancelled: one per cycle would pile up.
	it('re-arms one timer for every cycle', () => {
		let r = run(h.world(kernel_of(SPOKE_B)), MAIN);
		tick(r);
		tick(r);
		tick(r);
		assert.match([ 2, [ 0, 1500, 1500, 1500, 1500 ] ], [ r.loop.created, map(r.loop.timers, (t) => t.ms) ]);
	});

	it('accepts the ubus_rpc_session argument uhttpd adds to calls from LuCI', () => {
		let w = h.world(kernel_of(SPOKE_B));
		run(w, MAIN);
		assert.match({ ubus_rpc_session: '' }, w.ubus.published.wgpathd.status.args);
	});

	it('logs the start with the role, mode and peer counts, and the stop', () => {
		let w = h.world(kernel_of(SPOKE_B));
		run(w, MAIN, substrate([ SPOKE_B_PEER ], { hub: { '.type': 'wireguard_wg_mesh', public_key: HUB } }));
		assert.match([
			[ 'notice', 'started role=spoke mode=steer managed=1 unmanaged=1' ],
			[ 'notice', 'stopped' ],
		], w.logs.matching(/^(started|stopped)/));
	});

	it('logs the network sections left with the options of an earlier version once, at start', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let legacy = { hub: { '.type': 'wireguard_wg_mesh', public_key: HUB, wgpathd_relay: '10.10.0.1:51820',
			wgpathd_tunnel: '10.20.0.1' } };
		let r = run(w, MAIN, substrate([ SPOKE_B_PEER ], legacy));
		reload(r, { ...MAIN, cycle: '1' }, substrate([ SPOKE_B_PEER ], legacy));
		assert.match([ [ 'warning', 'network section hub: ignoring wgpathd_relay and wgpathd_tunnel, left over from an ' +
			'earlier version; run service wgpathd migrate' ] ], w.logs.matching(/left over/));
		assert.match([ HUB_UNMANAGED ], r.status().unmanaged);
	});

	it('exits 1 with a logged reason on an invalid configuration', () => {
		let w = h.world(kernel_of(SPOKE_B));
		let r = run(w, { ...MAIN, role: 'relay' });
		assert.match(1, r.code);
		assert.match(false, r.loop.ran);
		assert.match([ [ 'err', 'invalid configuration: CONFIG_INVALID_ROLE (relay)' ] ], w.logs.entries);
	});

	it('exits 1 with a logged reason when startup fails', () => {
		let w = h.world(kernel_of(SPOKE_B), { iface: 'wg_other' });
		let r = run(w, MAIN);
		assert.match(1, r.code);
		assert.match(true, r.loop.ended);
		assert.match({}, w.ubus.published);
		assert.match([ 'err', 'notice' ], map(w.logs.matching(/^startup failed: INTERFACE_MISSING|^stopped/), (e) => e[0]));
		assert.match([ 'notice', 'stopped code=1' ], w.logs.entries[-1]);
	});
});

describe('daemon: reload on SIGHUP', () => {
	function reachable_world() {
		let w = h.world(kernel_of(SPOKE_B, SPOKE_A), { files: cache_of({ [SPOKE_B]: SPOKE_B_DIRECT, [SPOKE_A]: SPOKE_A_DIRECT }) });
		w.reachable['2001:db8::12'] = true;
		w.reachable['2001:db8::11'] = true;
		return w;
	}

	it('keeps the state of an unchanged peer and starts a new one from RELAY', () => {
		let w = reachable_world();
		let r = run(w, MAIN);
		tick(r);
		assert.match(2, r.status().peers[SPOKE_B].up_streak);

		reload(r, MAIN, substrate([ SPOKE_B_PEER, SPOKE_A_PEER ]));
		assert.match(2, r.status().peers[SPOKE_B].up_streak);
		assert.match(contains({ state: 'RELAY', up_streak: 0, section: 'spoke_a' }), r.status().peers[SPOKE_A]);
		tick(r);
		assert.match([ 3, 1 ], [ r.status().peers[SPOKE_B].up_streak, r.status().peers[SPOKE_A].up_streak ]);
		assert.match([ [ 'notice', 'configuration reloaded peers_kept=1 added=1 removed=0' ] ],
			w.logs.matching(/reloaded/));
		assert.match([ [ 'info', `${A}: added` ] ], w.logs.matching(/: (added|removed|changed)$/));
	});

	it('drops a removed peer from steering and status', () => {
		let w = reachable_world();
		let r = run(w, MAIN, substrate([ SPOKE_B_PEER, SPOKE_A_PEER ]));
		reload(r, MAIN, substrate([ SPOKE_B_PEER ]));
		let seen = length(w.exec.commands());
		let probed = length(w.icmp.sent);
		tick(r);
		assert.match([ SPOKE_B ], keys(r.status().peers));
		assert.match([], filter(commands_since(w, seen), (c) => index(c, SPOKE_A) >= 0));
		assert.match([ '2001:db8::12' ], probed_since(w, probed));
		assert.match(1, length(w.logs.matching(/peers_kept=1 added=0 removed=1/)));
		assert.match([ [ 'info', `${A}: removed` ] ], w.logs.matching(/: (added|removed|changed)$/));
	});

	it('starts a peer afresh when its settings change, and guards its new relay', () => {
		let w = reachable_world();
		let r = run(w, MAIN);
		tick(r);
		reload(r, MAIN, substrate([ { ...SPOKE_B_PEER, relay: '10.10.0.99:51820' } ]));
		assert.match(contains({ up_streak: 0, endpoint: null }), r.status().peers[SPOKE_B]);
		tick(r);
		assert.match(set_all(SPOKE_B, '10.10.0.99:51820'),
			filter(w.exec.commands(), (c) => index(c, 'wg set') == 0)[-1]);
		assert.match([ [ 'info', `${B}: changed` ] ], w.logs.matching(/: (added|removed|changed)$/));
		assert.match(1, length(w.logs.matching(/peers_kept=0 added=1 removed=1/)));

		w.routes['10.10.0.98'] = 'wg_mesh';
		reload(r, MAIN, substrate([ { ...SPOKE_B_PEER, relay: '10.10.0.98:51820' } ]));
		assert.match({}, r.status().peers);
		assert.match([ { section: 'spoke_b', pubkey: SPOKE_B, reason: 'relay routes into wg_mesh' } ], r.status().unmanaged);
	});

	it('steers a rejected peer once a reload finds its relay route fixed', () => {
		let w = reachable_world();
		w.routes['10.10.0.12'] = 'wg_mesh';
		let r = run(w, MAIN);
		delete w.routes['10.10.0.12'];
		reload(r, MAIN, substrate([ SPOKE_B_PEER ]));
		assert.match([], r.status().unmanaged);
		assert.match(contains({ state: 'RELAY', section: 'spoke_b' }), r.status().peers[SPOKE_B]);
		assert.match([ [ 'notice', `${B}: relay route found, now managed` ] ], w.logs.matching(/route found/));
	});

	it('keeps a still-misrouted peer rejected across a reload, logging it once', () => {
		let w = reachable_world();
		w.routes['10.10.0.12'] = 'wg_mesh';
		let r = run(w, MAIN);
		reload(r, { ...MAIN, cycle: '1' }, substrate([ SPOKE_B_PEER ]));
		assert.match([ { section: 'spoke_b', pubkey: SPOKE_B, reason: 'relay routes into wg_mesh' } ], r.status().unmanaged);
		assert.match(1, length(w.logs.matching(/^peer spoke_b .*unmanaged/)));
	});

	it('applies parameters, mode and the discovery url live', () => {
		let w = reachable_world();
		let r = run(w, MAIN);
		let other = 'http://10.10.0.1:7781/peers';
		reload(r, { ...MAIN, cycle: '2', mode: 'observe', discovery: other }, substrate([ SPOKE_B_PEER ]));
		tick(r);
		assert.match(2000, r.loop.timers[-1].ms);
		assert.match('observe', r.status().mode);
		assert.match([ URL, other ], w.http.calls, 'fetched at once from the new url');
		assert.match([ [ 'notice', 'configuration reloaded peers_kept=1 added=0 removed=0 mode=observe' ] ],
			w.logs.matching(/reloaded/));
	});

	it('ends the loop on a structural change, for procd to respawn', () => {
		let w = reachable_world();
		let r = run(w, MAIN);
		reload(r, { ...MAIN, mesh_iface: 'wg_mesh2' }, substrate([ SPOKE_B_PEER ], { wg_mesh2: { '.type': 'interface', proto: 'wireguard' } }));
		assert.match(true, r.loop.ended);
		assert.match([ [ 'notice', 'reload: exiting for procd to start afresh changed=mesh_iface' ] ],
			w.logs.matching(/^reload/));
	});

	it('keeps the running configuration when the new one is invalid', () => {
		let w = reachable_world();
		let r = run(w, MAIN);
		reload(r, { ...MAIN, role: 'relay' }, substrate([ SPOKE_B_PEER ]));
		assert.match(false, r.loop.ended);
		assert.match([ [ 'err', 'reload: invalid configuration, keeping the running one: CONFIG_INVALID_ROLE (relay)' ] ],
			w.logs.matching(/^reload/));
		tick(r);
		assert.match(contains({ role: 'spoke', mode: 'steer' }), r.status());
		assert.match(1500, r.loop.timers[-1].ms);
	});

	it('keeps the running parameters when a new one is out of bounds', () => {
		let w = reachable_world();
		let r = run(w, MAIN);
		reload(r, { ...MAIN, cycle: '0.0001', mode: 'observe' }, substrate([ SPOKE_B_PEER ]));
		assert.match([ [ 'err', 'reload: invalid configuration, keeping the running one: CONFIG_INVALID_OPTION (cycle must be a number from 1 to 10)' ] ],
			w.logs.matching(/^reload/));
		tick(r);
		assert.match([ 1500, 'steer' ], [ r.loop.timers[-1].ms, r.status().mode ]);
	});

	it('defers a SIGHUP that arrives before startup completes', () => {
		let w = reachable_world();
		let loop = h.uloop();
		let run_loop = loop.run;
		loop.run = function() {
			loop.signals.SIGHUP();
			run_loop();
		};
		run(w, MAIN, null, loop);
		assert.match([ 'started role=spoke mode=steer managed=1 unmanaged=0', 'configuration reloaded peers_kept=1 added=0 removed=0' ],
			map(w.logs.matching(/started|reloaded/), (e) => e[1]));
	});
});

// The browser tests' fake wgpathd answers test/fixtures/luci/*.json as they are, so
// each must have the fields of the daemon's own reply, at every level.
describe('daemon: status fields of the LuCI browser fixtures', () => {
	const FIXTURES = sourcepath(0, true) + '/../fixtures/luci';
	// The publisher leaves out the handshake age of a peer never heard from.
	const OPTIONAL = { handshake_age: true };

	function kind(v) {
		return (type(v) == 'int' || type(v) == 'double') ? 'number' : type(v);
	}

	// Paths where `fixture` differs from `real`: a field missing or extra, or a value of
	// another type. A null on either side matches, as the reply has nulls for unset
	// values. Maps keyed by public key and arrays are compared entry by entry against
	// the first entry of `real`.
	function differences(real, fixture, path, keyed, out) {
		if (real == null || fixture == null)
			return out;
		if (kind(real) != kind(fixture)) {
			push(out, `${path}: ${kind(fixture)}, not ${kind(real)}`);
			return out;
		}
		if (type(real) == 'array') {
			for (let i, v in fixture)
				differences(real[0], v, `${path}[${i}]`, false, out);
			return out;
		}
		if (type(real) != 'object')
			return out;
		if (keyed) {
			let sample = values(real)[0];
			for (let k, v in fixture)
				differences(sample, v, `${path}.${k}`, false, out);
			return out;
		}
		for (let k in keys(real))
			if (!(k in fixture) && !OPTIONAL[k])
				push(out, `${path}.${k}: missing`);
		for (let k, v in fixture)
			if (k in real)
				differences(real[k], v, `${path}.${k}`, k == 'peers', out);
			else
				push(out, `${path}.${k}: not in the reply`);
		return out;
	}

	// A spoke with every field set: a peer back on the hub after a failed trial that
	// gave its address up, with its last change and the history, and an unmanaged peer.
	function spoke_reply() {
		let t = failed_trial({ overrides: { n_up: 1, trial_window: 6, give_up_after: 1 } });
		cycles(t.w, t.d, 3);
		let reply = t.d.status();
		assert.match('object', type(reply.peers[SPOKE_B].last_change));
		assert.match('object', type(reply.peers[SPOKE_B].given_up));
		assert.match(true, length(reply.history) > 0 && length(reply.unmanaged) > 0);
		return reply;
	}

	function hub_reply() {
		let w = h.world({ [SPOKE_B]: { endpoint: SPOKE_B_DIRECT, hs: 1790456491 } });
		return start(w, { role: 'hub', read_iface: 'wg_mesh', serve_addr: '10.10.0.1', serve_port: '7780',
			overrides: {} }).status();
	}

	it('match the fields and types of the reply of their role', () => {
		let real = { spoke: spoke_reply(), hub: hub_reply() };
		let files = filter(lsdir(FIXTURES), (f) => match(f, /\.json$/));
		assert.match(true, length(files) >= 9, 'fixtures found');
		for (let f in files) {
			let fixture = json(readfile(`${FIXTURES}/${f}`));
			assert.match([], differences(real[fixture.role == 'hub' ? 'hub' : 'spoke'], fixture, f, false, []), f);
		}
	});
});
