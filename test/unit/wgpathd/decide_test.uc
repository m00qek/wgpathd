import { describe, it, prop, gen, assert } from 'utest';
import * as state from 'wgpathd.state';
import * as effects from 'wgpathd.effects';
import { decide } from 'wgpathd.decide';

const P = { mode: 'steer', cycle: 3, n_up: 3, m_down: 2, tunnel_timeout: 1, trial_window: 8,
	backoff_min: 30, backoff_max: 900, backoff_reset: 600 };
const OBSERVE = { ...P, mode: 'observe' };

const RELAY_EP = '10.10.0.11:51820';
const TUNNEL   = '10.20.0.11';
const CAND     = '[2001:db8::a]:51820';
const CAND2    = '[2001:db8::b]:51820';
const ROAM     = '[2001:db8:ffff::5]:40000';
const ROAM2    = '[2001:db8:eeee::6]:40001';
const T0       = 1000.5;

const BASE = { underlay_ok: null, tunnel_ok: null, cur_endpoint: null, last_hs_ts: null,
	direct_cand: CAND, relay_endpoint: RELAY_EP, tunnel_addr: TUNNEL, discovery_fresh: true };

// By default the kernel endpoint is whatever we last asserted (no roam).
function sim(params) {
	let s = { ctl: state.init(), now: T0, params: params ?? P };

	s.cycle = function(o) {
		let out = decide(s.ctl, { ...BASE, cur_endpoint: s.ctl.asserted, ...o }, s.params, s.now);
		s.ctl = out.ctl;
		s.now += s.params.cycle;
		return out;
	};

	s.cycles = function(n, o) {
		let out;
		for (let i = 0; i < n; i++)
			out = s.cycle(o);
		return out;
	};

	return s;
}

function to_trialing(s, o) {
	return s.cycles(P.n_up, { underlay_ok: true, ...(o ?? {}) });
}

function to_direct(s) {
	to_trialing(s);
	return s.cycle({ tunnel_ok: true });
}

function of_kind(fx, kind) {
	return map(filter(fx, (e) => exists(e, kind)), (e) => e[kind]);
}

function endpoint(out) {
	let eps = of_kind(out.effects, 'set_endpoint');
	assert.match(1, length(eps));
	return eps[0];
}

function has(out, kind) {
	return length(of_kind(out.effects, kind)) > 0;
}

function logs(out) {
	return of_kind(out.effects, 'log');
}

describe('decide: first cycle and cold boot', () => {
	it('first cycle: any cur_endpoint is not a roam, set_endpoint(relay)', () => {
		for (let cur in [ null, RELAY_EP, CAND, ROAM ]) {
			let out = sim().cycle({ cur_endpoint: cur });
			assert.match(RELAY_EP, endpoint(out));
			assert.match(state.RELAY, out.ctl.state);
			assert.match(0, out.ctl.up_streak);
		}
	});

	it('first cycle records the relay as asserted', () => {
		assert.match(RELAY_EP, sim().cycle({}).ctl.asserted);
	});

	it('cold boot (R1): stale discovery, empty cache still sets the relay', () => {
		let out = sim().cycle({ discovery_fresh: false, direct_cand: null, underlay_ok: null });
		assert.match(RELAY_EP, endpoint(out));
		assert.match(true, has(out, 'refresh_discovery'));
		assert.match(true, effects.validate(out.effects));
	});
});

describe('decide: RELAY', () => {
	it('promotes to TRIALING after n_up cycles of underlay evidence', () => {
		let s = sim();
		let out = s.cycles(P.n_up - 1, { underlay_ok: true });
		assert.match(state.RELAY, out.ctl.state);
		out = s.cycle({ underlay_ok: true });
		assert.match(state.TRIALING, out.ctl.state);
		assert.match(CAND, out.ctl.target);
		assert.match(CAND, endpoint(out));
		assert.match([ TUNNEL ], of_kind(out.effects, 'tunnel_probe'));
	});

	it('sets the endpoint before sending the tunnel probe', () => {
		let fx = to_trialing(sim()).effects;
		let kinds = map(fx, (e) => keys(e)[0]);
		assert.match(true, index(kinds, 'set_endpoint') < index(kinds, 'tunnel_probe'));
	});

	it('logs trial_start and records it in last_change', () => {
		let s = sim();
		s.cycles(P.n_up - 1, { underlay_ok: true });
		let now = s.now;
		let out = s.cycle({ underlay_ok: true });
		assert.match([ { event: 'transition', from: state.RELAY, to: state.TRIALING, reason: 'trial_start' } ], logs(out));
		assert.match({ ts: now, from: state.RELAY, to: state.TRIALING, reason: 'trial_start' }, out.ctl.last_change);
	});

	it('sets the trial deadline trial_window after the start', () => {
		let s = sim();
		s.cycles(P.n_up - 1, { underlay_ok: true });
		let now = s.now;
		assert.match(now + P.trial_window, s.cycle({ underlay_ok: true }).ctl.trial_deadline);
	});

	it('stays on relay with fewer than n_up evidence cycles', () => {
		let out = sim().cycles(P.n_up - 1, { underlay_ok: true });
		assert.match(RELAY_EP, endpoint(out));
		assert.match(P.n_up - 1, out.ctl.up_streak);
		assert.match(false, has(out, 'tunnel_probe'));
	});

	it('a cycle without evidence resets the streak', () => {
		let s = sim();
		s.cycles(P.n_up - 1, { underlay_ok: true });
		assert.match(0, s.cycle({ underlay_ok: false }).ctl.up_streak);
		assert.match(state.RELAY, s.cycles(P.n_up - 1, { underlay_ok: true }).ctl.state);
	});

	it('underlay_ok null is no evidence', () => {
		let s = sim();
		s.cycles(2, { underlay_ok: true });
		assert.match(0, s.cycle({ underlay_ok: null }).ctl.up_streak);
	});

	it('underlay_ok without a direct candidate is no evidence', () => {
		let out = sim().cycles(P.n_up + 2, { underlay_ok: true, direct_cand: null });
		assert.match(state.RELAY, out.ctl.state);
		assert.match(0, out.ctl.up_streak);
	});

	it('a roam to a direct source counts as evidence while relay is re-asserted', () => {
		let s = sim();
		s.cycle({});
		let out = s.cycle({ cur_endpoint: ROAM, underlay_ok: false });
		assert.match(1, out.ctl.up_streak);
		assert.match(RELAY_EP, endpoint(out));
		assert.match(state.RELAY, out.ctl.state);
	});

	it('the trial target is the roam source when a roam is seen', () => {
		let s = sim();
		s.cycles(P.n_up - 1, { underlay_ok: true });
		let out = s.cycle({ underlay_ok: true, cur_endpoint: ROAM });
		assert.match(state.TRIALING, out.ctl.state);
		assert.match(ROAM, out.ctl.target);
		assert.match(ROAM, endpoint(out));
	});

	it('the trial target is the discovery candidate without a roam', () => {
		let s = sim();
		s.cycles(P.n_up - 1, { underlay_ok: true });
		assert.match(CAND2, s.cycle({ underlay_ok: true, direct_cand: CAND2 }).ctl.target);
	});

	it('the kernel sitting on the relay is not a roam', () => {
		let s = sim();
		s.cycle({});
		assert.match(0, s.cycle({ cur_endpoint: RELAY_EP }).ctl.up_streak);
	});

	it('emits refresh_discovery without evidence, not with it', () => {
		let s = sim();
		assert.match(true, has(s.cycle({ underlay_ok: false }), 'refresh_discovery'));
		assert.match(false, has(s.cycle({ underlay_ok: true }), 'refresh_discovery'));
	});

	it('waits for backoff_until before trialing, then trials at exactly backoff_until', () => {
		let s = sim();
		s.ctl = { ...s.ctl, backoff: 30, backoff_until: T0 + 4 * P.cycle };
		let out = s.cycles(4, { underlay_ok: true });
		assert.match(state.RELAY, out.ctl.state);
		assert.match(4, out.ctl.up_streak);
		assert.match(state.TRIALING, s.cycle({ underlay_ok: true }).ctl.state);
	});

	it('does not trial without a tunnel address to probe', () => {
		let out = sim().cycles(P.n_up + 2, { underlay_ok: true, tunnel_addr: null });
		assert.match(state.RELAY, out.ctl.state);
		assert.match(true, effects.validate(out.effects));
	});
});

describe('decide: TRIALING', () => {
	it('commits to DIRECT when the tunnel probe was answered', () => {
		let s = sim();
		to_trialing(s);
		let now = s.now;
		let out = s.cycle({ tunnel_ok: true });
		assert.match(state.DIRECT, out.ctl.state);
		assert.match(now, out.ctl.direct_since);
		assert.match(CAND, endpoint(out));
		assert.match([ TUNNEL ], of_kind(out.effects, 'tunnel_probe'));
		assert.match([ { event: 'transition', from: state.TRIALING, to: state.DIRECT, reason: 'trial_ok' } ], logs(out));
		assert.match({ ts: now, from: state.TRIALING, to: state.DIRECT, reason: 'trial_ok' }, out.ctl.last_change);
	});

	it('re-sets the target and re-probes while not yet answered', () => {
		for (let t in [ false, null ]) {
			let s = sim();
			to_trialing(s);
			let out = s.cycle({ tunnel_ok: t });
			assert.match(state.TRIALING, out.ctl.state);
			assert.match(CAND, endpoint(out));
			assert.match([ TUNNEL ], of_kind(out.effects, 'tunnel_probe'));
			assert.match([], logs(out));
		}
	});

	it('keeps the trial target even if discovery changes mid-trial', () => {
		let s = sim();
		to_trialing(s);
		assert.match(CAND, endpoint(s.cycle({ direct_cand: CAND2 })));
	});

	it('reverts to relay with backoff once the deadline passes', () => {
		let s = sim();
		let deadline = to_trialing(s).ctl.trial_deadline;
		s.cycles(2, { tunnel_ok: false });
		let now = s.now;
		assert.match(true, now >= deadline);
		let out = s.cycle({ tunnel_ok: false });
		assert.match(state.RELAY, out.ctl.state);
		assert.match(RELAY_EP, endpoint(out));
		assert.match(false, has(out, 'tunnel_probe'));
		assert.match(30, out.ctl.backoff);
		assert.match(now + 30, out.ctl.backoff_until);
		assert.match(null, out.ctl.target);
		assert.match([ { event: 'transition', from: state.TRIALING, to: state.RELAY, reason: 'trial_timeout' } ], logs(out));
	});

	it('times out at exactly the deadline', () => {
		let s = sim();
		let deadline = to_trialing(s).ctl.trial_deadline;
		s.now = deadline;
		assert.match(state.RELAY, s.cycle({}).ctl.state);
	});

	it('an answer seen at or after the deadline does not commit', () => {
		let s = sim();
		let deadline = to_trialing(s).ctl.trial_deadline;
		s.now = deadline + 0.5;
		assert.match(state.RELAY, s.cycle({ tunnel_ok: true }).ctl.state);
	});

	it('the revert cycle starts a fresh evidence streak', () => {
		let s = sim();
		to_trialing(s);
		assert.match(0, s.cycles(3, { underlay_ok: true }).ctl.up_streak);
	});
});

describe('decide: DIRECT', () => {
	it('re-asserts the target and probes every steady cycle', () => {
		let s = sim();
		to_direct(s);
		for (let i = 0; i < 5; i++) {
			let out = s.cycle({ tunnel_ok: true });
			assert.match(state.DIRECT, out.ctl.state);
			assert.match(CAND, endpoint(out));
			assert.match([ TUNNEL ], of_kind(out.effects, 'tunnel_probe'));
			assert.match(false, has(out, 'refresh_discovery'));
		}
	});

	it('demotes to relay after m_down consecutive failed probes', () => {
		let s = sim();
		to_direct(s);
		let out = s.cycle({ tunnel_ok: false });
		assert.match([ state.DIRECT, 1 ], [ out.ctl.state, out.ctl.down_streak ]);
		let now = s.now;
		out = s.cycle({ tunnel_ok: false });
		assert.match(state.RELAY, out.ctl.state);
		assert.match(RELAY_EP, endpoint(out));
		assert.match(false, has(out, 'tunnel_probe'));
		assert.match([ 30, now + 30 ], [ out.ctl.backoff, out.ctl.backoff_until ]);
		assert.match([ null, null ], [ out.ctl.target, out.ctl.direct_since ]);
		assert.match([ { event: 'transition', from: state.DIRECT, to: state.RELAY, reason: 'demoted' } ], logs(out));
		assert.match({ ts: now, from: state.DIRECT, to: state.RELAY, reason: 'demoted' }, out.ctl.last_change);
	});

	it('missed deadline: tunnel_ok null counts toward m_down', () => {
		let s = sim();
		to_direct(s);
		s.cycle({ tunnel_ok: null });
		assert.match(state.RELAY, s.cycle({ tunnel_ok: null }).ctl.state);
	});

	it('an answered probe resets down_streak', () => {
		let s = sim();
		to_direct(s);
		s.cycle({ tunnel_ok: false });
		assert.match(0, s.cycle({ tunnel_ok: true }).ctl.down_streak);
		assert.match(state.DIRECT, s.cycle({ tunnel_ok: false }).ctl.state);
	});

	it('roam in DIRECT (#9): adopts the new source, never the old target', () => {
		let s = sim();
		to_direct(s);
		let before = s.ctl.last_change;
		let out = s.cycle({ tunnel_ok: true, cur_endpoint: ROAM });
		assert.match(state.DIRECT, out.ctl.state);
		assert.match(ROAM, endpoint(out));
		assert.match([ ROAM, ROAM ], [ out.ctl.target, out.ctl.asserted ]);
		assert.match([ TUNNEL ], of_kind(out.effects, 'tunnel_probe'));
		assert.match([ { event: 'roam', from: state.DIRECT, to: state.DIRECT, reason: 'roam_adopted' } ], logs(out));
		assert.match(before, out.ctl.last_change);
		assert.match(ROAM, endpoint(s.cycle({ tunnel_ok: true })));
	});

	it('follows successive roams', () => {
		let s = sim();
		to_direct(s);
		s.cycle({ tunnel_ok: true, cur_endpoint: ROAM });
		assert.match(ROAM2, endpoint(s.cycle({ tunnel_ok: true, cur_endpoint: ROAM2 })));
	});

	it('roam to relay in DIRECT: re-asserts the target, no demotion', () => {
		let s = sim();
		to_direct(s);
		for (let i = 0; i < 4; i++) {
			let out = s.cycle({ tunnel_ok: true, cur_endpoint: RELAY_EP });
			assert.match(state.DIRECT, out.ctl.state);
			assert.match(CAND, endpoint(out));
			assert.match([], logs(out));
		}
	});

	it('demotion wins over a roam seen in the same cycle', () => {
		let s = sim();
		to_direct(s);
		s.cycle({ tunnel_ok: false });
		let out = s.cycle({ tunnel_ok: false, cur_endpoint: ROAM });
		assert.match(state.RELAY, out.ctl.state);
		assert.match(RELAY_EP, endpoint(out));
	});

	it('ignores discovery changes while held', () => {
		let s = sim();
		to_direct(s);
		assert.match(CAND, endpoint(s.cycle({ tunnel_ok: true, direct_cand: CAND2 })));
	});
});

describe('decide: backoff (G1)', () => {
	// One flap: wait out any backoff, earn a trial, commit, then fail m_down probes.
	function flap(s) {
		if (s.now < s.ctl.backoff_until)
			s.now = s.ctl.backoff_until;
		to_direct(s);
		return s.cycles(P.m_down, { tunnel_ok: false });
	}

	it('a demotion sets backoff_until, so the next good streak waits', () => {
		let s = sim();
		let until = flap(s).ctl.backoff_until;
		let waited = 0;
		while (s.now < until) {
			assert.match(state.RELAY, s.cycle({ underlay_ok: true }).ctl.state);
			waited++;
		}
		assert.match(true, waited > P.n_up);
		assert.match(state.TRIALING, s.cycle({ underlay_ok: true }).ctl.state);
	});

	it('repeated demotions double backoff up to backoff_max', () => {
		let s = sim();
		let seen = [];
		for (let i = 0; i < 7; i++)
			push(seen, flap(s).ctl.backoff);
		assert.match([ 30, 60, 120, 240, 480, 900, 900 ], seen);
	});

	it('failed trials and demotions share one backoff', () => {
		let s = sim();
		flap(s);
		s.now = s.ctl.backoff_until;
		to_trialing(s);
		let out = s.cycles(3, { tunnel_ok: false });
		assert.match([ state.RELAY, 60 ], [ out.ctl.state, out.ctl.backoff ]);
	});

	it('DIRECT held for backoff_reset clears it', () => {
		let s = sim();
		flap(s);
		flap(s);
		s.now = s.ctl.backoff_until;
		let since = to_direct(s).ctl.direct_since;
		while (s.now - since < P.backoff_reset)
			assert.match(60, s.cycle({ tunnel_ok: true }).ctl.backoff);
		assert.match(0, s.cycle({ tunnel_ok: true }).ctl.backoff);
		assert.match(30, s.cycles(P.m_down, { tunnel_ok: false }).ctl.backoff);
	});
});

describe('decide: failure-mode catalog', () => {
	it('trial false positive: echo ok but the tunnel never answers', () => {
		let s = sim();
		let deadline = to_trialing(s).ctl.trial_deadline;
		while (s.now < deadline)
			assert.match(state.TRIALING, s.cycle({ underlay_ok: true, tunnel_ok: false }).ctl.state);
		let out = s.cycle({ underlay_ok: true, tunnel_ok: false });
		assert.match(state.RELAY, out.ctl.state);
		assert.match(true, out.ctl.backoff_until > s.now);
	});

	it('no handshake needed (#18): frozen last_hs_ts, tunnel answers → commits and holds', () => {
		let s = sim();
		let frozen = T0 - 600;
		to_trialing(s, { last_hs_ts: frozen });
		assert.match(state.DIRECT, s.cycle({ tunnel_ok: true, last_hs_ts: frozen }).ctl.state);
		for (let i = 0; i < 200; i++)
			assert.match(state.DIRECT, s.cycle({ tunnel_ok: true, last_hs_ts: frozen }).ctl.state);
	});

	it('unidirectional loss (#10): every trial fails → never committed', () => {
		let s = sim();
		let trials = 0;
		for (let i = 0; i < 2000; i++) {
			let out = s.cycle({ underlay_ok: true, tunnel_ok: false });
			assert.match(true, out.ctl.state != state.DIRECT);
			if (out.ctl.last_change?.reason == 'trial_start' && out.ctl.last_change.ts == s.now - P.cycle)
				trials++;
		}
		assert.match(true, trials >= 3);
	});

	it('anchor (#17): echo fails but authenticated roams promote with the roam as target', () => {
		let s = sim();
		s.cycle({ underlay_ok: false });
		let out = s.cycles(P.n_up, { underlay_ok: false, cur_endpoint: ROAM });
		assert.match(state.TRIALING, out.ctl.state);
		assert.match(ROAM, out.ctl.target);
		assert.match(ROAM, endpoint(out));
	});

	it('neither end reachable (#15): parks in RELAY', () => {
		let s = sim();
		for (let i = 0; i < 100; i++) {
			let out = s.cycle({ underlay_ok: false });
			assert.match([ state.RELAY, RELAY_EP ], [ out.ctl.state, endpoint(out) ]);
		}
	});

	it('lying hub (#5): a bogus candidate fails its trial and backs off', () => {
		let s = sim();
		to_trialing(s, { direct_cand: CAND2 });
		let out = s.cycles(3, { direct_cand: CAND2 });
		assert.match([ state.RELAY, 30 ], [ out.ctl.state, out.ctl.backoff ]);
	});

	it('whole hub down, no roam (#2): DIRECT keeps working without discovery', () => {
		let s = sim();
		to_direct(s);
		let out = s.cycles(50, { tunnel_ok: true, discovery_fresh: false, direct_cand: null });
		assert.match([ state.DIRECT, CAND ], [ out.ctl.state, endpoint(out) ]);
	});
});

describe('decide: metric', () => {
	it('emits exactly one metric per cycle mirroring the new ctl', () => {
		let s = sim();
		for (let o in [ {}, { underlay_ok: true }, { underlay_ok: true }, { underlay_ok: true }, { tunnel_ok: true }, { tunnel_ok: false } ]) {
			let out = s.cycle(o);
			let m = of_kind(out.effects, 'metric');
			assert.match(1, length(m));
			assert.match({ state: out.ctl.state, up_streak: out.ctl.up_streak, down_streak: out.ctl.down_streak,
				backoff: out.ctl.backoff, ready: out.ctl.up_streak >= P.n_up }, m[0]);
		}
	});

	it('reports ready while a streak is held back by backoff', () => {
		let s = sim();
		s.ctl = { ...s.ctl, backoff: 30, backoff_until: T0 + 100 };
		let out = s.cycles(P.n_up, { underlay_ok: true });
		assert.match(true, of_kind(out.effects, 'metric')[0].ready);
	});
});

describe('decide: observe mode', () => {
	it('counts evidence but never leaves RELAY or probes the tunnel', () => {
		let s = sim(OBSERVE);
		for (let i = 0; i < 20; i++) {
			let out = s.cycle({ underlay_ok: true, tunnel_ok: true });
			assert.match([ state.RELAY, RELAY_EP ], [ out.ctl.state, endpoint(out) ]);
			assert.match(false, has(out, 'tunnel_probe'));
		}
		assert.match(20, s.ctl.up_streak);
	});

	it('reports ready once up_streak reaches n_up', () => {
		let s = sim(OBSERVE);
		assert.match(false, of_kind(s.cycles(P.n_up - 1, { underlay_ok: true }).effects, 'metric')[0].ready);
		assert.match(true, of_kind(s.cycle({ underlay_ok: true }).effects, 'metric')[0].ready);
	});

	it('still asks for discovery refresh without evidence', () => {
		assert.match(true, has(sim(OBSERVE).cycle({}), 'refresh_discovery'));
	});

	it('falls back to relay from a non-RELAY ctl', () => {
		let s = sim();
		to_direct(s);
		s.params = OBSERVE;
		let out = s.cycle({ tunnel_ok: true });
		assert.match([ state.RELAY, RELAY_EP ], [ out.ctl.state, endpoint(out) ]);
		assert.match(false, has(out, 'tunnel_probe'));
	});

	it('treats an unknown mode as observe', () => {
		let s = sim({ ...P, mode: 'bogus' });
		let out = s.cycles(10, { underlay_ok: true });
		assert.match(state.RELAY, out.ctl.state);
	});
});

describe('decide: purity and determinism', () => {
	it('does not mutate ctl, obs or params', () => {
		let s = sim();
		to_trialing(s);
		let ctl = s.ctl;
		let obs = { ...BASE, tunnel_ok: true, cur_endpoint: ROAM };
		let params = { ...P };
		let before = sprintf('%J', [ ctl, obs, params ]);
		decide(ctl, obs, params, s.now);
		assert.match(before, sprintf('%J', [ ctl, obs, params ]));
	});

	it('the same inputs give the same outputs', () => {
		let s = sim();
		to_trialing(s);
		let obs = { ...BASE, tunnel_ok: true };
		assert.match(sprintf('%J', decide(s.ctl, obs, P, s.now)), sprintf('%J', decide(s.ctl, obs, P, s.now)));
	});

	it('injected clock: a scenario replays identically at any time base', () => {
		let script = [ {}, { underlay_ok: true }, { underlay_ok: true }, { underlay_ok: true },
			{ tunnel_ok: false }, { tunnel_ok: true }, { tunnel_ok: false }, { tunnel_ok: null }, { underlay_ok: true } ];
		let runs = map([ T0, 987654.125 ], (t0) => {
			let s = sim();
			s.now = t0;
			return map(script, (o) => {
				let out = s.cycle(o);
				return [ out.ctl.state, out.ctl.up_streak, out.ctl.down_streak, out.ctl.backoff, endpoint(out) ];
			});
		});
		assert.match(runs[0], runs[1]);
	});
});

// Property tests: random plausible obs sequences, invariants checked after every step.
const STRANGER = '[2001:db8:dead::1]:51820';
const TRI = [ true, false, null ];
const STEPS = [ 3, 3, 3, 3, 3, 40, 700 ];
const MAX_TRIAL_CYCLES = int((P.trial_window + P.cycle - 1) / P.cycle);
const RECOVERY_BOUND = MAX_TRIAL_CYCLES + P.m_down;

const obs_choice = gen.tuple(gen.int(0, 2), gen.int(0, 2), gen.int(0, 4), gen.int(0, 2), gen.int(0, length(STEPS) - 1));
const sequence = gen.array(obs_choice, { max_len: 80 });

function make_obs(ctl, c) {
	return { ...BASE,
		underlay_ok: TRI[c[0]],
		tunnel_ok: TRI[c[1]],
		cur_endpoint: [ RELAY_EP, ctl.asserted, CAND, STRANGER, null ][c[2]],
		direct_cand: [ CAND, CAND2, null ][c[3]] };
}

// Runs a random sequence, calling check(out, obs, prev_ctl) after each step.
function replay(seq, params, check) {
	let ctl = state.init();
	let now = T0;
	for (let c in seq) {
		let obs = make_obs(ctl, c);
		let out = decide(ctl, obs, params, now);
		check(out, obs, ctl);
		ctl = out.ctl;
		now += STEPS[c[4]];
	}
	return { ctl: ctl, now: now };
}

function roam_of(prev, obs) {
	let cur = obs.cur_endpoint;
	return (prev.asserted != null && cur != null && cur != prev.asserted && cur != obs.relay_endpoint) ? cur : null;
}

describe('decide: invariants', () => {
	prop('I1: effects stay inside the vocabulary', sequence, (seq, ctx) => {
		let reached = {};
		replay(seq, P, (out) => {
			assert.match(true, effects.validate(out.effects));
			assert.match(1, length(of_kind(out.effects, 'metric')));
			assert.match(true, length(of_kind(out.effects, 'tunnel_probe')) <= 1);
			reached[out.ctl.state] = true;
		});
		ctx.classify('reached DIRECT', reached[state.DIRECT] === true);
		ctx.classify('reached TRIALING', reached[state.TRIALING] === true);
	});

	prop('I2: the chosen endpoint is the relay, a seen candidate or a seen roam', sequence, (seq) => {
		let seen = {};
		replay(seq, P, (out, obs, prev) => {
			if (obs.direct_cand != null) seen[obs.direct_cand] = true;
			let roam = roam_of(prev, obs);
			if (roam != null) seen[roam] = true;
			let ep = endpoint(out);
			assert.match(true, ep == obs.relay_endpoint || seen[ep] === true);
		});
	});

	prop('I3: every cycle asserts exactly one endpoint; RELAY asserts the relay', sequence, (seq) => {
		replay(seq, P, (out) => {
			let ep = endpoint(out);
			assert.match(ep, out.ctl.asserted);
			if (out.ctl.state == state.RELAY)
				assert.match(RELAY_EP, ep);
			else
				assert.match(out.ctl.target, ep);
		});
	});

	const no_signal = gen.array(gen.tuple(gen.int(1, 2), gen.int(1, 2), gen.int(0, 1), gen.int(0, 2), gen.constant(0)),
		{ len: RECOVERY_BOUND + 5 });

	prop('I4: absent any direct signal, every reachable state reaches RELAY in time', gen.tuple(sequence, no_signal), (p, ctx) => {
		let start = replay(p[0], P, (out) => {});
		ctx.classify(`from ${start.ctl.state}`);
		let ctl = start.ctl;
		let now = start.now;
		for (let i = 0; i < length(p[1]); i++) {
			let c = p[1][i];
			let obs = { ...make_obs(ctl, c), cur_endpoint: [ ctl.asserted, RELAY_EP ][c[2]] };
			assert.match(null, roam_of(ctl, obs));
			ctl = decide(ctl, obs, P, now).ctl;
			now += P.cycle;
			if (i + 1 >= RECOVERY_BOUND)
				assert.match(state.RELAY, ctl.state);
		}
	});

	prop('I5: observe mode only ever sets the relay and never probes the tunnel', sequence, (seq) => {
		replay(seq, OBSERVE, (out) => {
			assert.match(RELAY_EP, endpoint(out));
			assert.match(false, has(out, 'tunnel_probe'));
			assert.match(state.RELAY, out.ctl.state);
		});
	});

	prop('decide never mutates its inputs', sequence, (seq) => {
		let ctl = state.init();
		let now = T0;
		for (let c in seq) {
			let obs = make_obs(ctl, c);
			let before = sprintf('%J', [ ctl, obs ]);
			let out = decide(ctl, obs, P, now);
			assert.match(before, sprintf('%J', [ ctl, obs ]));
			ctl = out.ctl;
			now += STEPS[c[4]];
		}
	});
});
