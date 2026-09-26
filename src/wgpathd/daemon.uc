'use strict';

// Imperative shell: gather obs, decide per peer, apply effects; hub snapshots, ubus status, watchdog, SIGHUP reload.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import * as wg from 'wgpathd.wg';
import * as probe from 'wgpathd.probe';
import * as discovery from 'wgpathd.discovery';
import * as config from 'wgpathd.config';
import * as parameters from 'wgpathd.params';
import * as publisher from 'wgpathd.publisher';
import * as state from 'wgpathd.state';
import * as relay from 'wgpathd.relay';
import { decide } from 'wgpathd.decide';

export const CACHE_PATH = '/var/run/wgpathd/cache.json';

const SET_TIMEOUT   = 2;
const FETCH_TIMEOUT = 5000;
const REFRESH_GAP   = 10;
const WATCHDOG      = { name: 'wgpathd', instance: 'wgpathd' };

// Options a running daemon cannot change: a reload that touches one exits, and procd respawns it.
const STRUCTURAL = [ 'role', 'mesh_iface', 'hub_iface', 'read_iface', 'serve_addr', 'serve_port' ];

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

function watchdog_pinger(deps) {
	let report = streak_reporter(deps, 'watchdog ping');
	return () => report(deps.ubus.call('service', 'watchdog', WATCHDOG));
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
	return { ...rec.metric, section: rec.peer.section, endpoint: rec.ctl.asserted, target: rec.ctl.target,
		switches: rec.switches, last_change: change };
}

function unmanaged_entry(peer, reason) {
	return { section: peer.section, pubkey: peer.pubkey, reason: reason };
}

function create_spoke(deps, cfg, params) {
	let records = [];
	let rejected = [];
	let waiting = [];
	let disc = { peers: {}, fresh: false, fetching: false, last_fetch: null, last_ok: null };
	let report_read = streak_reporter(deps, `reading ${cfg.mesh_iface}`);
	let report_discovery = streak_reporter(deps, 'discovery');
	let ping_watchdog = watchdog_pinger(deps);

	let log_peer = (level, rec, msg) => deps.log(level, `peer ${rec.peer.pubkey}: ${msg}`);
	let candidate = (rec) => disc.peers[rec.peer.pubkey]?.direct;

	let log_unmanaged = (u) => deps.log('info', `peer section ${u.section} unmanaged: ${u.reason}`);
	let manage = (peer) => push(records, peer_record(peer));

	let warn_invalid_mode = function() {
		if (cfg.invalid_mode != null)
			deps.log('warn', `unknown mode '${cfg.invalid_mode}', running in observe mode`);
	};

	let reject = function(peer, reason) {
		push(rejected, { peer: peer, reason: reason });
		log_unmanaged(unmanaged_entry(peer, reason));
	};

	// Returns the peers left waiting on a route lookup; they are retried every cycle.
	let guard_relays = function(peers, on_managed) {
		let still = [];
		for (let peer in peers) {
			let v = relay.guard(deps.route_get, cfg.mesh_iface, peer);
			if (v.verdict == relay.MANAGED) {
				manage(peer);
				if (on_managed)
					on_managed(peer);
			}
			else if (v.verdict == relay.REJECTED)
				reject(peer, v.reason);
			else
				push(still, { peer: peer, reason: v.reason });
		}
		return still;
	};

	let guard_new = function(peers) {
		let still = guard_relays(peers);
		for (let w in still)
			log_unmanaged(unmanaged_entry(w.peer, w.reason));
		waiting = [ ...waiting, ...still ];
	};

	let recheck_relays = function() {
		waiting = guard_relays(map(waiting, (w) => w.peer),
			(peer) => deps.log('info', `peer ${peer.pubkey}: relay route found, now managed`));
	};

	let unmanaged_entries = () => [
		...cfg.peers.unmanaged,
		...map(rejected, (r) => unmanaged_entry(r.peer, r.reason)),
		...map(waiting, (w) => unmanaged_entry(w.peer, w.reason)),
	];

	// A peer keeps its ctl only while its annotations are unchanged. A rejected peer
	// is guarded again, since the route it was rejected for may have been fixed.
	let reconcile = function(peers) {
		let same = (a, b) => a.pubkey == b.pubkey && a.relay == b.relay && a.tunnel == b.tunnel;
		let take = (list, peer) => filter(list, (x) => same(x.peer, peer))[0];
		let old = { records: records, rejected: rejected, waiting: waiting };
		records = [];
		rejected = [];
		waiting = [];
		let fresh = [];
		let retry = [];
		for (let peer in peers) {
			let rec = take(old.records, peer);
			let rej = rec ? null : take(old.rejected, peer);
			let wait = (rec || rej) ? null : take(old.waiting, peer);
			if (rec) {
				rec.peer = peer;
				push(records, rec);
			}
			else if (rej)
				push(retry, peer);
			else if (wait)
				push(waiting, { ...wait, peer: peer });
			else
				push(fresh, peer);
		}
		let before = length(old.records) + length(old.rejected) + length(old.waiting);
		let kept = length(peers) - length(fresh);
		return { fresh: fresh, retry: retry, summary: { kept: kept, added: length(fresh), removed: before - kept } };
	};

	// Re-guards rejected peers quietly: only a peer that became steerable is logged.
	let reguard = function(peers) {
		for (let peer in peers) {
			let v = relay.guard(deps.route_get, cfg.mesh_iface, peer);
			if (v.verdict == relay.MANAGED) {
				manage(peer);
				deps.log('info', `peer ${peer.pubkey}: relay route found, now managed`);
			}
			else if (v.verdict == relay.REJECTED)
				push(rejected, { peer: peer, reason: v.reason });
			else
				push(waiting, { peer: peer, reason: v.reason });
		}
	};

	let underlay_task = (rec, argv, results) => (done) => {
		deps.exec(argv, probe.backstop(params.tunnel_timeout), (res) => {
			results[rec.peer.pubkey] = probe.reachable(res);
			done();
		});
	};

	let gather = function(cb) {
		let read = null;
		let underlay = {};
		let tasks = [ (done) => read_peers(deps, cfg.mesh_iface, (res) => { read = res; done(); }) ];
		for (let rec in records) {
			let argv = probe.underlay_command(candidate(rec), params.tunnel_timeout);
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
		if (!rec.report_set)
			rec.report_set = streak_reporter(deps, `peer ${rec.peer.pubkey}: setting endpoint`);
		deps.exec(wg.set_endpoint_command(cfg.mesh_iface, rec.peer.pubkey, addr), SET_TIMEOUT, (res) => {
			let err = command_error(res, errors.WG_COMMAND_FAILED);
			rec.report_set(err ?? Result.ok());
			if (err != null)
				return done();
			if (probe_addr == null)
				return done();
			let argv = probe.tunnel_command(probe_addr, params.tunnel_timeout);
			deps.exec(argv, probe.backstop(params.tunnel_timeout), (pres) => {
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
		report_discovery(res);
		if (!res.ok)
			return;
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
			warn_invalid_mode();
			read_peers(deps, cfg.mesh_iface, (res) => {
				if (!res.ok)
					return done(Result.err(errors.INTERFACE_MISSING, `${cfg.mesh_iface}: ${Result.describe(res)}`));
				for (let u in cfg.peers.unmanaged)
					log_unmanaged(u);
				guard_new(cfg.peers.managed);
				disc.peers = discovery.load_cache(deps.fs, CACHE_PATH);
				done(Result.ok());
			});
		},

		reload: function(new_cfg, new_params) {
			let seen = map(cfg.peers.unmanaged, (u) => `${u.section} ${u.reason}`);
			if (new_cfg.discovery != cfg.discovery)
				disc.last_fetch = null;
			cfg = new_cfg;
			params = new_params;
			warn_invalid_mode();
			for (let u in cfg.peers.unmanaged)
				if (!(`${u.section} ${u.reason}` in seen))
					log_unmanaged(u);
			let diff = reconcile(cfg.peers.managed);
			reguard(diff.retry);
			guard_new(diff.fresh);
			return diff.summary;
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
					ping_watchdog();
					done();
				});
			});
		},

		status: function() {
			let peers = {};
			for (let rec in records)
				peers[rec.peer.pubkey] = peer_status(rec, deps.clock);
			return { role: 'spoke', mode: cfg.mode, discovery: { fresh: disc.fresh, last_ok: disc.last_ok },
				peers: peers, unmanaged: unmanaged_entries() };
		},
	};
}

// Every hub option is structural, so a reload has nothing to apply here.
function create_hub(deps, cfg) {
	let peers = {};
	let report_read = streak_reporter(deps, `reading ${cfg.read_iface}`);
	let ping_watchdog = watchdog_pinger(deps);

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
			ping_watchdog();
			done();
		}),
		reload: () => null,
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
	daemon.cycle(() => deps.uloop.timer(int(cycle() * 1000), () => loop(deps, daemon, cycle)));
}

// Also on stderr: a manual run, or a container without logd, has no syslog to read.
function fatal(deps, msg) {
	deps.log('error', msg);
	deps.stderr(msg);
	return 1;
}

export function structural_change(old, cfg) {
	for (let opt in STRUCTURAL)
		if (old[opt] != cfg[opt])
			return opt;
	return null;
};

function describe_reload(summary) {
	if (summary == null)
		return 'configuration reloaded';
	return `configuration reloaded (peers: ${summary.kept} kept, ${summary.added} added, ${summary.removed} removed)`;
}

export function run(deps) {
	let load_config = () => config.load({ ...deps, uci: deps.uci_cursor() });
	let loaded = load_config();
	if (!loaded.ok)
		return fatal(deps, `invalid configuration: ${Result.describe(loaded)}`);
	let cfg = loaded.data;
	let params = parameters.build(cfg);
	let daemon = create(deps, cfg, params);
	let code = 0;
	let started = false;
	let reload_pending = false;

	let reload = function() {
		if (!started) {
			reload_pending = true;
			return;
		}
		let res = load_config();
		if (!res.ok)
			return deps.log('error', `reload: invalid configuration, keeping the running one: ${Result.describe(res)}`);
		let changed = structural_change(cfg, res.data);
		if (changed != null) {
			deps.log('info', `reload: ${changed} changed, exiting for procd to start afresh`);
			return deps.uloop.end();
		}
		cfg = res.data;
		params = parameters.build(cfg);
		deps.log('info', describe_reload(daemon.reload(cfg, params)));
	};
	let hup = deps.uloop.signal('SIGHUP', reload);

	// Started from inside the loop: uloop.run() clears an end() that came before it.
	deps.uloop.timer(0, () => daemon.start((res) => {
		let up = res.ok ? serve(deps, cfg, daemon) : res;
		if (!up.ok) {
			code = fatal(deps, `startup failed: ${Result.describe(up)}`);
			return deps.uloop.end();
		}
		deps.log('info', `started as ${cfg.role}`);
		started = true;
		loop(deps, daemon, () => params.cycle);
		if (reload_pending)
			reload();
	}));
	deps.uloop.run();
	hup?.delete();
	return code;
};
