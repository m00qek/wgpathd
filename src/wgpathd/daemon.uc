'use strict';

// Imperative shell: gather obs, decide per peer, apply effects; hub snapshots, ubus status, watchdog.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import * as endpoint from 'wgpathd.endpoint';
import * as wg from 'wgpathd.wg';
import * as probe from 'wgpathd.probe';
import * as discovery from 'wgpathd.discovery';
import * as config from 'wgpathd.config';
import * as parameters from 'wgpathd.params';
import * as publisher from 'wgpathd.publisher';
import * as state from 'wgpathd.state';
import { decide } from 'wgpathd.decide';

export const CACHE_PATH = '/var/run/wgpathd/cache.json';

const SET_TIMEOUT   = 2;
const FETCH_TIMEOUT = 5000;
const REFRESH_GAP   = 10;
const WATCHDOG      = { name: 'wgpathd', instance: 'wgpathd' };

// Runs every task (each takes a completion callback), then calls done once.
function all(tasks, done) {
	let left = length(tasks);
	if (left == 0)
		return done();
	for (let task in tasks)
		task(() => {
			if (--left == 0)
				done();
		});
}

function command_error(res, code) {
	if (!res.ok)
		return Result.err(code, Result.describe(res));
	if (res.data.code != 0)
		return Result.err(code, `exit ${res.data.code}`);
	return null;
}

function read_peers(deps, iface, cb) {
	deps.ubus.defer('wireguard', 'status', {}, (res) => {
		cb(res.ok ? wg.parse_status(res.data, iface) : res);
	});
}

// Logs the first failure of a streak and the recovery, not every failing cycle.
function streak_reporter(deps, what) {
	let failing = false;
	return function(res) {
		if (!res.ok && !failing)
			deps.log('warn', `${what} failed: ${Result.describe(res)}`);
		else if (res.ok && failing)
			deps.log('info', `${what} recovered`);
		failing = !res.ok;
	};
}

function ping_watchdog(deps) {
	let res = deps.ubus.call('service', 'watchdog', WATCHDOG);
	if (!res.ok)
		deps.log('warn', `watchdog ping failed: ${Result.describe(res)}`);
}

function peer_record(peer) {
	let ctl = state.init();
	return {
		peer: peer,
		ctl: ctl,
		tunnel_ok: null,
		absent: false,
		switches: 0,
		metric: { state: ctl.state, up_streak: ctl.up_streak, down_streak: ctl.down_streak,
			backoff: ctl.backoff, ready: false },
	};
}

// ctl keeps monotonic time; status shows wall-clock seconds.
function peer_status(rec, clock) {
	let change = rec.ctl.last_change;
	if (change != null)
		change = { ...change, ts: int(clock.wall() - (clock.now() - change.ts)) };
	return { ...rec.metric, endpoint: rec.ctl.asserted, target: rec.ctl.target,
		switches: rec.switches, last_change: change };
}

function unmanaged_entry(peer, reason) {
	return { section: peer.section, pubkey: peer.pubkey, reason: reason };
}

function create_spoke(deps, cfg, params) {
	let records = [];
	let unmanaged = [ ...cfg.peers.unmanaged ];
	let waiting = [];
	let disc = { peers: {}, fresh: false, fetching: false, last_fetch: null, last_ok: null };
	let report_read = streak_reporter(deps, `reading ${cfg.mesh_iface}`);

	let log_peer = (level, rec, msg) => deps.log(level, `peer ${rec.peer.pubkey}: ${msg}`);
	let candidate = (rec) => disc.peers[rec.peer.pubkey]?.direct;

	let log_unmanaged = (u) => deps.log('info', `peer section ${u.section} unmanaged: ${u.reason}`);
	let manage = (peer) => push(records, peer_record(peer));

	// A relay routed into mesh_iface is a configuration error and stays unmanaged; a
	// failed lookup (wg_hub not up yet at boot) is returned to be retried next cycle.
	let guard_relays = function(peers, on_managed) {
		let still = [];
		for (let peer in peers) {
			let res = deps.route_get(endpoint.host(peer.relay));
			if (!res.ok) {
				push(still, { peer: peer, reason: `relay route lookup failed: ${Result.describe(res)}` });
			}
			else if (res.data.oif == cfg.mesh_iface) {
				let entry = unmanaged_entry(peer, `relay routes into ${cfg.mesh_iface}`);
				push(unmanaged, entry);
				log_unmanaged(entry);
			}
			else {
				on_managed(peer);
			}
		}
		return still;
	};

	let waiting_entries = () => map(waiting, (w) => unmanaged_entry(w.peer, w.reason));

	let recheck_relays = function() {
		waiting = guard_relays(map(waiting, (w) => w.peer), (peer) => {
			manage(peer);
			deps.log('info', `peer ${peer.pubkey}: relay route found, now managed`);
		});
	};

	let underlay_task = (rec, argv, results) => (done) => {
		deps.exec(argv, params.tunnel_timeout, (res) => {
			results[rec.peer.pubkey] = probe.reachable(res);
			done();
		});
	};

	let gather = function(cb) {
		let read = null;
		let underlay = {};
		let tasks = [ (done) => read_peers(deps, cfg.mesh_iface, (res) => { read = res; done(); }) ];
		for (let rec in records) {
			let argv = probe.underlay_command(candidate(rec));
			if (argv != null)
				push(tasks, underlay_task(rec, argv, underlay));
		}
		all(tasks, () => cb(read, underlay));
	};

	// tunnel_ok answers the previous cycle's probe only, so it is consumed even for a skipped peer.
	let build_obs = function(rec, kernel_peers, underlay_ok) {
		let tunnel_ok = rec.tunnel_ok;
		rec.tunnel_ok = null;
		if (kernel_peers == null)
			return null;
		let kernel = kernel_peers[rec.peer.pubkey];
		if (kernel == null) {
			if (!rec.absent)
				log_peer('warn', rec, `absent from ${cfg.mesh_iface}, skipped`);
			rec.absent = true;
			return null;
		}
		rec.absent = false;
		return {
			underlay_ok: underlay_ok ?? null,
			tunnel_ok: tunnel_ok,
			cur_endpoint: kernel.endpoint,
			last_hs_ts: kernel.last_hs_ts,
			direct_cand: candidate(rec),
			relay_endpoint: rec.peer.relay,
			tunnel_addr: rec.peer.tunnel,
			discovery_fresh: disc.fresh,
		};
	};

	let record_log = function(rec, entry) {
		if (entry.event == 'transition')
			rec.switches++;
		log_peer('info', rec, `${entry.event} ${entry.from} -> ${entry.to} (${entry.reason})`);
	};

	// The probe leaves only on an endpoint that was actually set, so a failed
	// `wg set` cannot let a probe over the old path commit a trial.
	let set_then_probe = function(rec, addr, probe_addr, done) {
		deps.exec(wg.set_endpoint_command(cfg.mesh_iface, rec.peer.pubkey, addr), SET_TIMEOUT, (res) => {
			let err = command_error(res, errors.WG_COMMAND_FAILED);
			if (err != null) {
				log_peer('warn', rec, `setting endpoint ${addr} failed: ${Result.describe(err)}`);
				return done();
			}
			if (probe_addr == null)
				return done();
			deps.exec(probe.tunnel_command(probe_addr), params.tunnel_timeout, (pres) => {
				rec.tunnel_ok = probe.reachable(pres);
				done();
			});
		});
	};

	let apply_task = (rec, effects) => (done) => {
		let addr = null;
		let probe_addr = null;
		for (let e in effects) {
			if (exists(e, 'set_endpoint'))
				addr = e.set_endpoint;
			else if (exists(e, 'tunnel_probe'))
				probe_addr = e.tunnel_probe;
			else if (exists(e, 'log'))
				record_log(rec, e.log);
			else if (exists(e, 'metric'))
				rec.metric = e.metric;
		}
		set_then_probe(rec, addr, probe_addr, done);
	};

	let fetch_result = function(res) {
		if (res.ok && res.data.status != 200)
			return Result.err(errors.DISCOVERY_FETCH_FAILED, `HTTP ${res.data.status}`);
		return res.ok ? discovery.parse(res.data.body) : res;
	};

	let take_payload = function(res) {
		disc.fresh = res.ok;
		if (!res.ok)
			return deps.log('warn', `discovery failed: ${Result.describe(res)}`);
		disc.peers = res.data;
		disc.last_ok = deps.clock.wall();
		if (!discovery.save_cache(deps.fs, CACHE_PATH, res.data))
			deps.log('warn', `cannot save the discovery cache to ${CACHE_PATH}`);
	};

	let fetch_due = function(now, wants_refresh) {
		if (disc.last_fetch == null)
			return true;
		let since = now - disc.last_fetch;
		return since >= params.discovery_interval || (wants_refresh && since >= REFRESH_GAP);
	};

	// Never awaited: discovery must not slow the cycle, and so failover, while the hub is down.
	let refresh_discovery = function(now, wants_refresh) {
		if (disc.fetching || !fetch_due(now, wants_refresh))
			return;
		disc.last_fetch = now;
		disc.fetching = true;
		deps.http.get(cfg.discovery, FETCH_TIMEOUT, discovery.MAX_BYTES, (res) => {
			disc.fetching = false;
			take_payload(fetch_result(res));
		});
	};

	return {
		start: function(done) {
			if (cfg.invalid_mode != null)
				deps.log('warn', `unknown mode '${cfg.invalid_mode}', running in observe mode`);
			read_peers(deps, cfg.mesh_iface, (res) => {
				if (!res.ok)
					return done(Result.err(errors.INTERFACE_MISSING, `${cfg.mesh_iface}: ${Result.describe(res)}`));
				for (let u in unmanaged)
					log_unmanaged(u);
				waiting = guard_relays(cfg.peers.managed, manage);
				for (let u in waiting_entries())
					log_unmanaged(u);
				disc.peers = discovery.load_cache(deps.fs, CACHE_PATH);
				done(Result.ok());
			});
		},

		cycle: function(done) {
			recheck_relays();
			gather((read, underlay) => {
				report_read(read);
				let kernel_peers = read.ok ? read.data : null;
				let now = deps.clock.now();
				let wants_refresh = false;
				let jobs = [];
				for (let rec in records) {
					let obs = build_obs(rec, kernel_peers, underlay[rec.peer.pubkey]);
					if (obs == null)
						continue;
					let out = decide(rec.ctl, obs, params, now);
					rec.ctl = out.ctl;
					wants_refresh ||= length(filter(out.effects, (e) => e.refresh_discovery)) > 0;
					push(jobs, apply_task(rec, out.effects));
				}
				all(jobs, () => {
					refresh_discovery(now, wants_refresh);
					ping_watchdog(deps);
					done();
				});
			});
		},

		status: function() {
			let peers = {};
			for (let rec in records)
				peers[rec.peer.pubkey] = peer_status(rec, deps.clock);
			return { role: 'spoke', mode: cfg.mode, discovery: { fresh: disc.fresh, last_ok: disc.last_ok },
				peers: peers, unmanaged: [ ...unmanaged, ...waiting_entries() ] };
		},
	};
}

function create_hub(deps, cfg) {
	let peers = {};
	let report_read = streak_reporter(deps, `reading ${cfg.read_iface}`);

	let take_snapshot = (cb) => read_peers(deps, cfg.read_iface, (res) => {
		if (res.ok)
			peers = publisher.snapshot(res.data, deps.clock.wall());
		cb(res);
	});

	return {
		start: (done) => take_snapshot((res) => {
			done(res.ok ? Result.ok() : Result.err(errors.INTERFACE_MISSING, `${cfg.read_iface}: ${Result.describe(res)}`));
		}),
		cycle: (done) => take_snapshot((res) => {
			report_read(res);
			ping_watchdog(deps);
			done();
		}),
		status: () => ({ role: 'hub', peers: peers }),
	};
}

export function create(deps, cfg, params) {
	return (cfg.role == 'hub') ? create_hub(deps, cfg) : create_spoke(deps, cfg, params);
};

function serve(deps, cfg, daemon) {
	let res = deps.ubus.publish('wgpathd', { status: { args: {}, call: () => daemon.status() } });
	if (!res.ok || cfg.role != 'hub')
		return res;
	return publisher.listen(deps, cfg.serve_addr, +cfg.serve_port, () => daemon.status().peers);
}

function loop(deps, daemon, cycle) {
	daemon.cycle(() => deps.uloop.timer(int(cycle * 1000), () => loop(deps, daemon, cycle)));
}

// Also on stderr: a manual run, or a container without logd, has no syslog to read.
function fatal(deps, msg) {
	deps.log('error', msg);
	deps.stderr(msg);
	return 1;
}

export function run(deps) {
	let loaded = config.load(deps);
	if (!loaded.ok)
		return fatal(deps, `invalid configuration: ${Result.describe(loaded)}`);
	let cfg = loaded.data;
	let params = parameters.build(cfg);
	let daemon = create(deps, cfg, params);
	let code = 0;

	// Started from inside the loop: uloop.run() clears an end() that came before it.
	deps.uloop.timer(0, () => daemon.start((res) => {
		let up = res.ok ? serve(deps, cfg, daemon) : res;
		if (!up.ok) {
			code = fatal(deps, `startup failed: ${Result.describe(up)}`);
			return deps.uloop.end();
		}
		deps.log('info', `started as ${cfg.role}`);
		loop(deps, daemon, params.cycle);
	}));
	deps.uloop.run();
	return code;
};
