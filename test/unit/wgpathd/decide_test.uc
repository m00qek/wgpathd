import { describe, it, prop, gen, assert, contains } from 'utest';
import * as state from 'wgpathd.state';
import * as effects from 'wgpathd.effects';
import { decide, trial_target } from 'wgpathd.decide';

const P = { mode: 'steer', cycle: 3, n_up: 3, m_down: 2, tunnel_timeout: 1, trial_window: 8,
	backoff_min: 30, backoff_max: 900, backoff_reset: 600, give_up_after: 3, give_up_pause: 21600 };
const OBSERVE = { ...P, mode: 'observe' };

const RELAY_EP = '10.10.0.11:51820';
const TUNNEL   = '10.20.0.11';
const CAND     = '[2001:db8::a]:51820';
const CAND2    = '[2001:db8::b]:51820';
const ROAM     = '[2001:db8:ffff::5]:40000';
const ROAM2    = '[2001:db8:eeee::6]:40001';
const T0       = 1000.5;

const BASE = { underlay_ok: null, tunnel_ok: null, answered_via: null, cur_endpoint: null, last_hs_ts: null,
	direct_cand: CAND, relay_endpoint: RELAY_EP, tunnel_addr: TUNNEL, discovery_fresh: true };

// By default the kernel endpoint is whatever we last asserted (no roam), and an
// answered probe came back on the endpoint it was sent to.
function sim(params) {
	let s = { ctl: state.init(), now: T0, params: params ?? P };

	s.cycle = function(o) {
		let obs = { ...BASE, cur_endpoint: s.ctl.asserted, answered_via: s.ctl.asserted, ...o };
		let out = decide(s.ctl, obs, s.params, s.now);
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

	it('cold boot: stale discovery, empty cache still sets the relay', () => {
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

	it('a roam during a backoff counts as evidence while relay is re-asserted', () => {
		let s = sim();
		s.cycle({});
		s.ctl = { ...s.ctl, backoff: 30, backoff_until: s.now + 10 };
		let out = s.cycle({ cur_endpoint: ROAM, underlay_ok: false });
		assert.match(1, out.ctl.up_streak);
		assert.match(RELAY_EP, endpoint(out));
		assert.match(state.RELAY, out.ctl.state);
		assert.match(true, of_kind(out.effects, 'metric')[0].ready);
	});

	it('a roam starts a trial at once, toward the roam source', () => {
		let s = sim();
		s.cycle({});
		let out = s.cycle({ cur_endpoint: ROAM, underlay_ok: false });
		assert.match(state.TRIALING, out.ctl.state);
		assert.match(ROAM, out.ctl.target);
		assert.match(ROAM, endpoint(out));
		assert.match([ TUNNEL ], of_kind(out.effects, 'tunnel_probe'));
		assert.match([ { event: 'transition', from: state.RELAY, to: state.TRIALING, reason: 'trial_start' } ], logs(out));
	});

	it('a roam trials as soon as the backoff expires', () => {
		let s = sim();
		s.cycle({});
		s.ctl = { ...s.ctl, backoff: 30, backoff_until: s.now + 2 * P.cycle };
		assert.match(state.RELAY, s.cycles(2, { cur_endpoint: ROAM }).ctl.state);
		assert.match(state.TRIALING, s.cycle({ cur_endpoint: ROAM }).ctl.state);
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

	it('an answer that came back over the relay does not commit', () => {
		let s = sim();
		to_trialing(s);
		let out = s.cycle({ tunnel_ok: true, answered_via: RELAY_EP });
		assert.match(state.TRIALING, out.ctl.state);
		assert.match(CAND, endpoint(out));
		assert.match([ TUNNEL ], of_kind(out.effects, 'tunnel_probe'));
		assert.match([], logs(out));
		assert.match(state.DIRECT, s.cycle({ tunnel_ok: true }).ctl.state);
	});

	it('answers that only ever come over the relay time out with backoff', () => {
		let s = sim();
		let deadline = to_trialing(s).ctl.trial_deadline;
		while (s.now < deadline)
			assert.match(state.TRIALING, s.cycle({ tunnel_ok: true, answered_via: RELAY_EP }).ctl.state);
		let out = s.cycle({ tunnel_ok: true, answered_via: RELAY_EP });
		assert.match([ state.RELAY, 30 ], [ out.ctl.state, out.ctl.backoff ]);
		assert.match([ { event: 'transition', from: state.TRIALING, to: state.RELAY, reason: 'trial_timeout' } ], logs(out));
	});

	it('an answer that came back from another direct address does not commit the target', () => {
		let s = sim();
		to_trialing(s);
		let out = s.cycle({ tunnel_ok: true, answered_via: ROAM });
		assert.match([ state.TRIALING, CAND ], [ out.ctl.state, endpoint(out) ]);
		assert.match(state.DIRECT, s.cycle({ tunnel_ok: true, answered_via: CAND }).ctl.state);
	});

	it('a trial on a roam commits on an answer from that roam', () => {
		let s = sim();
		s.cycle({});
		assert.match(ROAM, s.cycle({ cur_endpoint: ROAM }).ctl.target);
		assert.match(state.TRIALING, s.cycle({ tunnel_ok: true, answered_via: ROAM2 }).ctl.state);
		assert.match(state.DIRECT, s.cycle({ tunnel_ok: true, answered_via: ROAM }).ctl.state);
	});

	it('an answer that came back direct commits, wherever relay traffic has moved the kernel since', () => {
		let s = sim();
		to_trialing(s);
		assert.match(state.DIRECT, s.cycle({ tunnel_ok: true, cur_endpoint: RELAY_EP }).ctl.state);
	});

	it('an answer whose path could not be read does not commit', () => {
		let s = sim();
		to_trialing(s);
		assert.match(state.TRIALING, s.cycle({ tunnel_ok: true, answered_via: null }).ctl.state);
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

	it('roam in DIRECT: adopts the new source, never the old target', () => {
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
			assert.match([ state.DIRECT, 0 ], [ out.ctl.state, out.ctl.down_streak ]);
			assert.match(CAND, endpoint(out));
			assert.match([], logs(out));
		}
	});

	it('an answer from another direct address holds DIRECT, and the roam there is adopted', () => {
		let s = sim();
		to_direct(s);
		let out = s.cycle({ tunnel_ok: true, answered_via: ROAM, cur_endpoint: ROAM });
		assert.match([ state.DIRECT, 0, ROAM ], [ out.ctl.state, out.ctl.down_streak, endpoint(out) ]);
		assert.match(0, s.cycle({ tunnel_ok: true, answered_via: ROAM2 }).ctl.down_streak);
	});

	it('answers read back on the relay still hold DIRECT', () => {
		let s = sim();
		to_direct(s);
		for (let i = 0; i < P.m_down + 2; i++) {
			let out = s.cycle({ tunnel_ok: true, answered_via: RELAY_EP });
			assert.match([ state.DIRECT, 0, CAND ], [ out.ctl.state, out.ctl.down_streak, endpoint(out) ]);
			assert.match([], logs(out));
		}
	});

	it('an answer whose endpoint could not be read still holds DIRECT', () => {
		let s = sim();
		to_direct(s);
		let out = s.cycle({ tunnel_ok: true, answered_via: null });
		assert.match([ state.DIRECT, 0 ], [ out.ctl.state, out.ctl.down_streak ]);
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

describe('decide: backoff', () => {
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

describe('decide: failure modes', () => {
	it('trial false positive: echo ok but the tunnel never answers', () => {
		let s = sim();
		let deadline = to_trialing(s).ctl.trial_deadline;
		while (s.now < deadline)
			assert.match(state.TRIALING, s.cycle({ underlay_ok: true, tunnel_ok: false }).ctl.state);
		let out = s.cycle({ underlay_ok: true, tunnel_ok: false });
		assert.match(state.RELAY, out.ctl.state);
		assert.match(true, out.ctl.backoff_until > s.now);
	});

	it('no handshake needed: frozen last_hs_ts, tunnel answers → commits and holds', () => {
		let s = sim();
		let frozen = T0 - 600;
		to_trialing(s, { last_hs_ts: frozen });
		assert.match(state.DIRECT, s.cycle({ tunnel_ok: true, last_hs_ts: frozen }).ctl.state);
		for (let i = 0; i < 200; i++)
			assert.match(state.DIRECT, s.cycle({ tunnel_ok: true, last_hs_ts: frozen }).ctl.state);
	});

	it('unidirectional loss: every trial fails → never committed', () => {
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

	it('anchor: echo fails but an authenticated roam promotes with the roam as target', () => {
		let s = sim();
		s.cycle({ underlay_ok: false });
		let out = s.cycle({ underlay_ok: false, cur_endpoint: ROAM });
		assert.match(state.TRIALING, out.ctl.state);
		assert.match(ROAM, out.ctl.target);
		assert.match(ROAM, endpoint(out));
		assert.match(state.DIRECT, s.cycle({ underlay_ok: false, tunnel_ok: true, cur_endpoint: ROAM }).ctl.state);
	});

	it('dead direct path under relay traffic: answers over the relay never commit', () => {
		for (let c in [ [ P, [ 30, 60, 120 ] ], [ { ...P, give_up_after: 100 }, [ 30, 60, 120, 240, 480, 900 ] ] ]) {
			let s = sim(c[0]);
			let backoffs = [];
			for (let i = 0; i < 2000; i++) {
				let out = s.cycle({ underlay_ok: true, tunnel_ok: (s.ctl.state == state.RELAY) ? null : true,
					cur_endpoint: RELAY_EP, answered_via: RELAY_EP });
				assert.match(true, out.ctl.state != state.DIRECT);
				if (out.ctl.last_change?.reason == 'trial_timeout' && out.ctl.last_change.ts == s.now - P.cycle)
					push(backoffs, out.ctl.backoff);
			}
			assert.match(c[1], slice(backoffs, 0, 6), 'the backoff grows until the address is given up');
		}
	});

	it('neither end reachable: parks in RELAY', () => {
		let s = sim();
		for (let i = 0; i < 100; i++) {
			let out = s.cycle({ underlay_ok: false });
			assert.match([ state.RELAY, RELAY_EP ], [ out.ctl.state, endpoint(out) ]);
		}
	});

	it('lying hub: a bogus candidate fails its trial and backs off', () => {
		let s = sim();
		to_trialing(s, { direct_cand: CAND2 });
		let out = s.cycles(3, { direct_cand: CAND2 });
		assert.match([ state.RELAY, 30 ], [ out.ctl.state, out.ctl.backoff ]);
	});

	it('whole hub down, no roam: DIRECT keeps working without discovery', () => {
		let s = sim();
		to_direct(s);
		let out = s.cycles(50, { tunnel_ok: true, discovery_fresh: false, direct_cand: null });
		assert.match([ state.DIRECT, CAND ], [ out.ctl.state, endpoint(out) ]);
	});
});

describe('decide: giving up a direct address', () => {
	const CAND_PORT = '[2001:db8::a]:51821';

	// Waits out any backoff and cycles on the echo until a trial starts; returns its start.
	function start_trial(s, o) {
		if (s.now < s.ctl.backoff_until)
			s.now = s.ctl.backoff_until;
		let out;
		for (let i = 0; i <= P.n_up && s.ctl.state == state.RELAY; i++)
			out = s.cycle({ underlay_ok: true, ...(o ?? {}) });
		assert.match(state.TRIALING, out.ctl.state, 'a trial started');
		return out;
	}

	// A trial on the echo whose tunnel probe is never answered; returns its timeout.
	function fail_trial(s, o) {
		start_trial(s, o);
		let out;
		while (s.ctl.state == state.TRIALING)
			out = s.cycle({ underlay_ok: true, tunnel_ok: false, direct_cand: o?.direct_cand ?? CAND });
		assert.match('trial_timeout', out.ctl.last_change.reason);
		return out;
	}

	function give_up(s, o) {
		let out;
		for (let i = 0; i < P.give_up_after; i++)
			out = fail_trial(s, o);
		assert.match(true, out.ctl.given_up_at != null, 'given up');
		return out;
	}

	function kinds(out) {
		return map(out.effects, (e) => keys(e)[0]);
	}

	function ready(out) {
		return of_kind(out.effects, 'metric')[0].ready;
	}

	it('starts with no failed trial', () => {
		assert.match([ null, 0, null ], [ state.init().failed_target, state.init().failed_trials, state.init().given_up_at ]);
	});

	it('counts a trial timeout against the trial target', () => {
		let out = fail_trial(sim());
		assert.match([ CAND, 1, null ], [ out.ctl.failed_target, out.ctl.failed_trials, out.ctl.given_up_at ]);
	});

	it('counts timeouts on the same target in a row; another target, a changed port included, starts afresh', () => {
		let s = sim();
		fail_trial(s);
		assert.match(2, fail_trial(s).ctl.failed_trials);
		let out = fail_trial(s, { direct_cand: CAND2 });
		assert.match([ CAND2, 1 ], [ out.ctl.failed_target, out.ctl.failed_trials ]);
		out = fail_trial(s, { direct_cand: CAND_PORT });
		assert.match([ CAND_PORT, 1 ], [ out.ctl.failed_target, out.ctl.failed_trials ]);
	});

	it('gives the address up at the give_up_after-th timeout in a row, and says so once, after the transition', () => {
		let s = sim();
		for (let i = 1; i < P.give_up_after; i++) {
			let out = fail_trial(s);
			assert.match([ null, false ], [ out.ctl.given_up_at, has(out, 'given_up') ]);
		}
		let out = fail_trial(s);
		let now = s.now - P.cycle;
		assert.match([ state.RELAY, now, P.give_up_after ], [ out.ctl.state, out.ctl.given_up_at, out.ctl.failed_trials ]);
		assert.match([ { endpoint: CAND, failed_trials: P.give_up_after } ], of_kind(out.effects, 'given_up'));
		assert.match(true, index(kinds(out), 'log') < index(kinds(out), 'given_up'));
		assert.match(true, effects.validate(out.effects));
		assert.match(false, has(s.cycle({ underlay_ok: true }), 'given_up'));
	});

	it('a trial that commits clears the count', () => {
		let s = sim();
		fail_trial(s);
		fail_trial(s);
		start_trial(s);
		let out = s.cycle({ tunnel_ok: true });
		assert.match([ state.DIRECT, null, 0, null ], [ out.ctl.state, out.ctl.failed_target, out.ctl.failed_trials, out.ctl.given_up_at ]);
	});

	// The path carried the peer's traffic, so the address is right: the backoff, not
	// giving up, handles a path that keeps passing its trial and failing soon after.
	it('a demotion is not a failed trial, however often the path passes its trial and dies', () => {
		let s = sim();
		fail_trial(s);
		for (let i = 0; i < 10; i++) {
			start_trial(s);
			s.cycle({ tunnel_ok: true });
			let out = s.cycles(P.m_down, { tunnel_ok: false });
			assert.match([ state.RELAY, 'demoted', 0, null ],
				[ out.ctl.state, out.ctl.last_change.reason, out.ctl.failed_trials, out.ctl.given_up_at ]);
		}
	});

	it('while given up, the echo alone starts no trial: the peer stays on the relay and keeps counting evidence', () => {
		let s = sim();
		let given_up_at = give_up(s).ctl.given_up_at;
		let streak = s.ctl.up_streak;
		while (s.now < given_up_at + P.give_up_pause - P.cycle) {
			let out = s.cycle({ underlay_ok: true });
			assert.match([ state.RELAY, RELAY_EP, false ], [ out.ctl.state, endpoint(out), ready(out) ]);
			assert.match([ false, false ], [ has(out, 'tunnel_probe'), has(out, 'refresh_discovery') ]);
			assert.match([], logs(out));
		}
		assert.match(true, s.ctl.up_streak > streak);
	});

	it('a roam trials at once toward its source, and says why trials resumed', () => {
		for (let roam in [ ROAM, CAND ]) {
			let s = sim();
			give_up(s);
			s.now = s.ctl.backoff_until;
			let out = s.cycle({ cur_endpoint: roam });
			assert.match([ state.TRIALING, roam, null ], [ out.ctl.state, out.ctl.target, out.ctl.given_up_at ]);
			assert.match([ { endpoint: CAND, reason: 'roam' } ], of_kind(out.effects, 'resumed'));
			assert.match(true, index(kinds(out), 'resumed') < index(kinds(out), 'log'));
			assert.match(true, effects.validate(out.effects));
		}
	});

	it('a roam while given up still waits for the backoff', () => {
		let s = sim();
		give_up(s);
		let out = s.cycle({ cur_endpoint: ROAM });
		assert.match([ state.RELAY, true ], [ out.ctl.state, ready(out) ]);
		s.now = s.ctl.backoff_until;
		assert.match(state.TRIALING, s.cycle({ cur_endpoint: ROAM }).ctl.state);
	});

	it('a trial on a roam from the given-up address that fails gives it up again at once', () => {
		let s = sim();
		give_up(s);
		s.now = s.ctl.backoff_until;
		s.cycle({ cur_endpoint: CAND });
		let out;
		while (s.ctl.state == state.TRIALING)
			out = s.cycle({ tunnel_ok: false });
		assert.match([ CAND, P.give_up_after + 1, true ], [ out.ctl.failed_target, out.ctl.failed_trials, out.ctl.given_up_at != null ]);
	});

	it('a different candidate trials on its echo, and says why trials resumed', () => {
		let s = sim();
		give_up(s);
		let out = start_trial(s, { direct_cand: CAND2 });
		assert.match([ CAND2, null ], [ out.ctl.target, out.ctl.given_up_at ]);
		assert.match([ { endpoint: CAND, reason: 'new_candidate' } ], of_kind(out.effects, 'resumed'));
	});

	it('a failed trial on the different candidate counts afresh', () => {
		let s = sim();
		give_up(s);
		let out = fail_trial(s, { direct_cand: CAND2 });
		assert.match([ CAND2, 1, null ], [ out.ctl.failed_target, out.ctl.failed_trials, out.ctl.given_up_at ]);
	});

	it('a candidate that goes away and comes back as the same address stays given up', () => {
		let s = sim();
		give_up(s);
		s.cycles(3, { direct_cand: null });
		let out = s.cycles(P.n_up + 5, { underlay_ok: true });
		assert.match([ state.RELAY, false ], [ out.ctl.state, ready(out) ]);
	});

	it('once the pause is over, the echo starts one more trial; its failure gives up again at once and restarts the pause', () => {
		let s = sim();
		let given_up_at = give_up(s).ctl.given_up_at;
		s.cycles(P.n_up, { underlay_ok: true });
		s.now = given_up_at + P.give_up_pause - 1;
		assert.match(state.RELAY, s.cycle({ underlay_ok: true }).ctl.state);
		s.now = given_up_at + P.give_up_pause;
		let out = s.cycle({ underlay_ok: true });
		assert.match([ state.TRIALING, CAND ], [ out.ctl.state, out.ctl.target ]);
		assert.match([ { endpoint: CAND, reason: 'pause_over' } ], of_kind(out.effects, 'resumed'));

		while (s.ctl.state == state.TRIALING)
			out = s.cycle({ underlay_ok: true, tunnel_ok: false });
		let again = s.now - P.cycle;
		assert.match([ again, P.give_up_after + 1 ], [ out.ctl.given_up_at, out.ctl.failed_trials ]);
		assert.match([ { endpoint: CAND, failed_trials: P.give_up_after + 1 } ], of_kind(out.effects, 'given_up'));
		s.now = again + P.give_up_pause - 1;
		assert.match(state.RELAY, s.cycle({ underlay_ok: true }).ctl.state);
	});

	it('the single trial after the pause commits on a path that works again', () => {
		let s = sim();
		let given_up_at = give_up(s).ctl.given_up_at;
		s.cycles(P.n_up, { underlay_ok: true });
		s.now = given_up_at + P.give_up_pause;
		assert.match(state.TRIALING, s.cycle({ underlay_ok: true }).ctl.state);
		let out = s.cycle({ tunnel_ok: true });
		assert.match([ state.DIRECT, 0, null ], [ out.ctl.state, out.ctl.failed_trials, out.ctl.given_up_at ]);
	});

	it('the backoff still holds a trial after the pause', () => {
		let p = { ...P, give_up_pause: 60, backoff_min: 300, backoff_max: 300 };
		let s = sim(p);
		for (let i = 0; i < p.give_up_after; i++) {
			if (s.now < s.ctl.backoff_until)
				s.now = s.ctl.backoff_until;
			s.cycles(p.n_up, { underlay_ok: true });
			while (s.ctl.state == state.TRIALING)
				s.cycle({ underlay_ok: true, tunnel_ok: false });
		}
		let until = s.ctl.backoff_until;
		assert.match(true, s.ctl.given_up_at + p.give_up_pause < until);
		s.now = s.ctl.given_up_at + p.give_up_pause;
		while (s.now < until)
			assert.match(state.RELAY, s.cycle({ underlay_ok: true }).ctl.state);
		assert.match(state.TRIALING, s.cycle({ underlay_ok: true }).ctl.state);
	});

	it('observe mode never trials, so never counts a failure', () => {
		let s = sim(OBSERVE);
		let out = s.cycles(2000, { underlay_ok: true, tunnel_ok: false });
		assert.match([ null, 0, null ], [ out.ctl.failed_target, out.ctl.failed_trials, out.ctl.given_up_at ]);
	});

	it('observe mode reports a given-up peer as not ready until the pause is over', () => {
		let s = sim();
		let given_up_at = give_up(s).ctl.given_up_at;
		s.params = OBSERVE;
		assert.match(false, ready(s.cycles(P.n_up + 1, { underlay_ok: true })));
		assert.match(true, ready(s.cycle({ underlay_ok: true, cur_endpoint: ROAM })), 'a roam would trial');
		s.now = given_up_at + P.give_up_pause;
		let out = s.cycle({ underlay_ok: true });
		assert.match([ true, state.RELAY, given_up_at ], [ ready(out), out.ctl.state, out.ctl.given_up_at ]);
	});
});

// The cost claims of docs/explanation/state-machine.md, "What a trial costs": while
// TRIALING, all of the peer's traffic takes the candidate path.
describe('decide: what trials cost over a day', () => {
	const DAY = 86400;
	const PER_TRIAL = P.trial_window + P.cycle;

	// Runs a day of cycles, obs(i, s) giving each cycle's observation.
	function day(params, obs) {
		let s = sim(params);
		let r = { trials: 0, trialing: 0, first_direct: null };
		for (let i = 0; s.now < T0 + DAY; i++) {
			let now = s.now;
			let out = s.cycle(obs(i, s));
			if (out.ctl.last_change?.ts == now && out.ctl.last_change.reason == 'trial_start')
				r.trials++;
			if (out.ctl.state == state.TRIALING)
				r.trialing += params.cycle;
			if (out.ctl.state == state.DIRECT && r.first_direct == null)
				r.first_direct = now;
		}
		return r;
	}

	const bad = () => ({ underlay_ok: true, tunnel_ok: false });

	it('a fixed address that answers ping but never carries WireGuard: give_up_after trials, then one per pause', () => {
		let r = day(P, bad);
		let bound = P.give_up_after + int((DAY + P.give_up_pause - 1) / P.give_up_pause);
		assert.match(true, r.trials > P.give_up_after && r.trials <= bound, `${r.trials} trials`);
		assert.match(true, r.trialing <= bound * PER_TRIAL, `${r.trialing} s trialing`);
		let before = day({ ...P, give_up_after: 100 }, bad);
		assert.match(true, before.trials >= DAY / (P.backoff_max + PER_TRIAL), `${before.trials} trials without giving up`);
		assert.match(true, r.trialing * 10 < before.trialing);
	});

	it('a hub that publishes another bad address every discovery_interval buys one trial per backoff', () => {
		let r = day(P, (i) => ({ ...bad(), direct_cand: sprintf('[2001:db8:bad::%x]:51820', int(i / 20)) }));
		let ramp = 6;
		assert.match(true, r.trials <= ramp + DAY / P.backoff_max, `${r.trials} trials`);
		assert.match(true, r.trialing <= (ramp + DAY / P.backoff_max) * PER_TRIAL, `${r.trialing} s trialing`);
	});

	it('a good address is taken at the first trial and held all day', () => {
		let r = day(P, () => ({ underlay_ok: true, tunnel_ok: true }));
		assert.match([ 1, P.cycle ], [ r.trials, r.trialing ]);
		assert.match(T0 + P.n_up * P.cycle, r.first_direct);
	});

	it('a good address that failed its trials during an outage is back within the pause, or at once on a roam', () => {
		let healed = T0 + 7200;
		let r = day(P, (i, s) => (s.now < healed) ? bad() : { underlay_ok: true, tunnel_ok: true });
		assert.match(true, r.first_direct > healed && r.first_direct <= healed + P.give_up_pause, `${r.first_direct - healed} s after`);

		let roam_at = healed + 60;
		r = day(P, (i, s) => (s.now < healed) ? bad()
			: { underlay_ok: true, tunnel_ok: true, cur_endpoint: (s.now >= roam_at && s.ctl.state == state.RELAY) ? CAND : s.ctl.asserted });
		assert.match(true, r.first_direct >= roam_at && r.first_direct <= roam_at + 2 * P.cycle, `${r.first_direct - roam_at} s after the roam`);
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

	it('reports ready on a roam seen in RELAY', () => {
		let s = sim(OBSERVE);
		s.cycle({});
		assert.match(true, of_kind(s.cycle({ cur_endpoint: ROAM }).effects, 'metric')[0].ready);
		assert.match(false, of_kind(s.cycle({}).effects, 'metric')[0].ready);
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
		let backoff = s.ctl.backoff;
		let out = s.cycle({ tunnel_ok: true });
		assert.match([ state.RELAY, RELAY_EP ], [ out.ctl.state, endpoint(out) ]);
		assert.match(false, has(out, 'tunnel_probe'));
		assert.match([ { event: 'transition', from: state.DIRECT, to: state.RELAY, reason: 'observe_mode' } ], logs(out));
		assert.match(contains({ from: state.DIRECT, to: state.RELAY, reason: 'observe_mode' }), out.ctl.last_change);
		assert.match(backoff, out.ctl.backoff, 'no backoff bump');
	});

	it('treats an unknown mode as observe', () => {
		let s = sim({ ...P, mode: 'bogus' });
		let out = s.cycles(10, { underlay_ok: true });
		assert.match(state.RELAY, out.ctl.state);
	});
});

describe('decide: trial_target', () => {
	it('is the roam when one was seen, else the candidate', () => {
		let s = sim(OBSERVE);
		s.cycle({});
		assert.match(CAND, trial_target(s.ctl, { ...BASE, cur_endpoint: RELAY_EP }));
		assert.match(ROAM, trial_target(s.ctl, { ...BASE, cur_endpoint: ROAM }));
	});

	it('is the target a trial started on the same obs takes', () => {
		for (let cur in [ RELAY_EP, ROAM ]) {
			let s = sim();
			s.cycles(P.n_up - 1, { underlay_ok: true });
			let obs = { ...BASE, underlay_ok: true, cur_endpoint: cur };
			assert.match(decide(s.ctl, obs, P, s.now).ctl.target, trial_target(s.ctl, obs));
		}
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
// The last step outlasts give_up_pause.
const STEPS = [ 3, 3, 3, 3, 3, 40, 700, 25000 ];
const MAX_TRIAL_CYCLES = int((P.trial_window + P.cycle - 1) / P.cycle);
const RECOVERY_BOUND = MAX_TRIAL_CYCLES + P.m_down;

const obs_choice = gen.tuple(gen.int(0, 2), gen.int(0, 2), gen.int(0, 4), gen.int(0, 2), gen.int(0, length(STEPS) - 1),
	gen.int(0, 4));

// Mostly an echo that answers, a probe that does not, no roam, the same candidate
// and short steps: the failed trials in a row that give an address up.
const sticky_choice = gen.tuple(
	gen.frequency([ 3, gen.constant(0) ], [ 1, gen.int(1, 2) ]),
	gen.frequency([ 1, gen.constant(0) ], [ 3, gen.int(1, 2) ]),
	gen.frequency([ 6, gen.constant(1) ], [ 1, gen.int(0, 4) ]),
	gen.frequency([ 8, gen.constant(0) ], [ 1, gen.int(1, 2) ]),
	gen.frequency([ 12, gen.int(0, 4) ], [ 2, gen.int(5, 6) ], [ 1, gen.constant(7) ]),
	gen.int(0, 4));

const sequence = gen.oneof(gen.array(obs_choice, { max_len: 80 }), gen.array(sticky_choice, { max_len: 150 }));

function make_obs(ctl, c) {
	return { ...BASE,
		underlay_ok: TRI[c[0]],
		tunnel_ok: TRI[c[1]],
		cur_endpoint: [ RELAY_EP, ctl.asserted, CAND, STRANGER, null ][c[2]],
		answered_via: [ ctl.asserted, RELAY_EP, STRANGER, null, CAND ][c[5]],
		direct_cand: [ CAND, CAND2, null ][c[3]] };
}

// Runs a random sequence, calling check(out, obs, prev_ctl, now) after each step.
function replay(seq, params, check) {
	let ctl = state.init();
	let now = T0;
	for (let c in seq) {
		let obs = make_obs(ctl, c);
		let out = decide(ctl, obs, params, now);
		check(out, obs, ctl, now);
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

	prop('I6: an answer that came back over the relay never commits a trial', sequence, (seq, ctx) => {
		replay(seq, P, (out, obs, prev) => {
			if (obs.answered_via != obs.relay_endpoint || prev.state != state.TRIALING)
				return;
			ctx.classify(obs.tunnel_ok === true ? 'answered' : 'unanswered');
			assert.match(true, out.ctl.state != state.DIRECT);
		});
	});

	prop('I7: a trial starts only once the backoff has run out', sequence, (seq, ctx) => {
		replay(seq, P, (out, obs, prev, now) => {
			if (prev.state != state.RELAY || out.ctl.state != state.TRIALING)
				return;
			ctx.classify(prev.backoff_until > T0 ? 'after a backoff' : 'no backoff yet');
			assert.match(true, now >= prev.backoff_until);
		});
	});

	prop('I8: a trial commits only on an answer from its target; DIRECT holds only on an answer', sequence, (seq, ctx) => {
		replay(seq, P, (out, obs, prev) => {
			if (out.ctl.state != state.DIRECT)
				return;
			if (prev.state == state.TRIALING) {
				ctx.classify('trial_ok');
				assert.match(true, obs.tunnel_ok === true && obs.answered_via == prev.target);
			}
			else if (prev.state == state.DIRECT && out.ctl.down_streak == 0) {
				ctx.classify('held');
				assert.match(true, obs.tunnel_ok === true);
			}
		});
	});

	// The shell sends the underlay probe only to a peer in RELAY. Outside RELAY the echo
	// changes no state and no effect, except whether a peer falling back asks for a refresh.
	prop('the underlay echo matters only in RELAY', sequence, (seq, ctx) => {
		let json_of = (x) => sprintf('%J', x);
		let but_refresh = (fx) => filter(fx, (e) => !exists(e, 'refresh_discovery'));
		replay(seq, P, (out, obs, prev, now) => {
			if (prev.state == state.RELAY)
				return;
			ctx.classify(`from ${prev.state}`);
			for (let u in TRI) {
				let alt = decide(prev, { ...obs, underlay_ok: u }, P, now);
				assert.match(json_of(out.ctl), json_of(alt.ctl));
				assert.match(json_of(but_refresh(out.effects)), json_of(but_refresh(alt.effects)));
				if (alt.ctl.state != state.RELAY)
					assert.match(json_of(out.effects), json_of(alt.effects));
			}
		});
	});

	// A change is a roam, a candidate other than the last one, the pause running out,
	// or a committed trial, which clears the count.
	prop('I9: between two changes, at most give_up_after trials start on the same target', sequence, (seq, ctx) => {
		let starts = {};
		let last_cand = null;
		let gave_up = false;
		replay(seq, P, (out, obs, prev, now) => {
			let changed = roam_of(prev, obs) != null
				|| (obs.direct_cand != null && last_cand != null && obs.direct_cand != last_cand)
				|| (prev.given_up_at != null && now >= prev.given_up_at + P.give_up_pause);
			last_cand = obs.direct_cand ?? last_cand;
			if (changed)
				starts = {};
			if (prev.state == state.RELAY && out.ctl.state == state.TRIALING) {
				starts[out.ctl.target] = (starts[out.ctl.target] ?? 0) + 1;
				assert.match(true, starts[out.ctl.target] <= P.give_up_after, out.ctl.target);
			}
			if (out.ctl.state == state.DIRECT)
				starts = {};
			gave_up ||= out.ctl.given_up_at != null;
		});
		ctx.classify('gave an address up', gave_up);
	});

	prop('while an address is given up, only a roam or another candidate starts a trial, until the pause is over',
		sequence, (seq, ctx) => {
		replay(seq, P, (out, obs, prev, now) => {
			if (prev.given_up_at == null || out.ctl.state != state.TRIALING)
				return;
			let roam = roam_of(prev, obs);
			let why = (roam != null) ? 'roam' : (out.ctl.target != prev.failed_target) ? 'new_candidate' : 'pause_over';
			ctx.classify(why);
			if (why == 'pause_over')
				assert.match(true, now >= prev.given_up_at + P.give_up_pause);
			assert.match([ { endpoint: prev.failed_target, reason: why } ], of_kind(out.effects, 'resumed'));
		});
	});

	prop('I5: observe mode only ever sets the relay and never probes the tunnel', sequence, (seq) => {
		replay(seq, OBSERVE, (out) => {
			assert.match(RELAY_EP, endpoint(out));
			assert.match(false, has(out, 'tunnel_probe'));
			assert.match(state.RELAY, out.ctl.state);
			assert.match(0, out.ctl.failed_trials);
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
