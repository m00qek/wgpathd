'use strict';

// The pure decision core for one peer: decide(ctl, obs, params, now) -> { ctl, effects }.

import * as state from 'wgpathd.state';
import * as fx from 'wgpathd.effects';

// A kernel endpoint we did not set, other than the relay, is an authenticated roam (R2).
function derive_roam(ctl, obs) {
	let cur = obs.cur_endpoint;
	if (ctl.asserted == null || cur == null || cur == ctl.asserted || cur == obs.relay_endpoint)
		return null;
	return cur;
}

function derive_evidence(ctl, obs) {
	let roam = derive_roam(ctl, obs);
	let echo = obs.underlay_ok === true && obs.direct_cand != null;
	return { roam: roam, present: echo || roam != null, target: roam ?? obs.direct_cand };
}

// A roam comes from a peer that is itself trialing or DIRECT toward us, and keeps
// coming only while we answer it directly: a re-asserted relay roams the peer back
// and fails its probe, so waiting n_up cycles would outlast its trial (R2, R4).
function is_ready(ctl, ev, params) {
	return (ctl.state == state.RELAY && ev.roam != null) || state.is_ready(ctl, params);
}

// A given-up address is not trialed on the underlay echo alone until the pause is
// over: a path that answers ping but cannot carry WireGuard would otherwise cost a
// trial window every backoff forever. A roam, or a candidate other than the given-up
// address, still trials.
function held_by_give_up(ctl, ev, params, now) {
	return ctl.given_up_at != null && ev.roam == null && ev.target == ctl.failed_target
		&& now < ctl.given_up_at + params.give_up_pause;
}

function may_trial(ctl, ev, params, now) {
	return is_ready(ctl, ev, params) && !held_by_give_up(ctl, ev, params, now);
}

function resume_reason(ctl, ev) {
	if (ev.roam != null)
		return 'roam';
	return (ev.target != ctl.failed_target) ? 'new_candidate' : 'pause_over';
}

// Relay traffic from the peer roams the kernel back onto the relay, so the probe may
// have left and come back that way. A trial commits to its target, so only an answer
// that came back from the target proves it (R4).
function trial_proven(ctl, obs) {
	return obs.tunnel_ok === true && obs.answered_via != null && obs.answered_via == ctl.target;
}

function relay_step(ctl, obs, ev, params, now, steering) {
	let next = { ...ctl, up_streak: ev.present ? ctl.up_streak + 1 : 0 };
	if (steering && obs.tunnel_addr && may_trial(next, ev, params, now) && now >= ctl.backoff_until)
		return { ctl: state.trialing(next, ev.target, now + params.trial_window), reason: 'trial_start',
			resumed: (ctl.given_up_at != null) ? resume_reason(ctl, ev) : null };
	return { ctl: next, reason: null };
}

// The deadline is checked first: an answer we cannot place before it does not commit.
function trialing_step(ctl, obs, params, now) {
	if (now >= ctl.trial_deadline)
		return { ctl: state.relay(state.count_failure(state.bump_backoff(ctl, params, now), params, now)),
			reason: 'trial_timeout' };
	if (trial_proven(ctl, obs))
		return { ctl: state.direct(ctl, now), reason: 'trial_ok' };
	return { ctl: ctl, reason: null };
}

// Any answer holds DIRECT, even one read back on the relay: while the peer still
// sends through the relay, its packets roam the kernel back after nearly every direct
// answer, and R4 here would demote a healthy path. A roam to another direct address
// is adopted below (R2).
function direct_step(ctl, obs, ev, params, now) {
	let down = (obs.tunnel_ok === true) ? 0 : ctl.down_streak + 1;
	if (down >= params.m_down)
		return { ctl: state.relay(state.bump_backoff(ctl, params, now)), reason: 'demoted' };

	let next = state.settle_backoff({ ...ctl, down_streak: down }, params, now);
	if (ev.roam != null)
		return { ctl: { ...next, target: ev.roam }, reason: 'roam_adopted' };
	return { ctl: next, reason: null };
}

// Anything but steer mode is observe: the safe reading of an unknown mode.
function step(ctl, obs, ev, params, now) {
	let steering = params.mode == 'steer';
	if (!steering && ctl.state != state.RELAY)
		return { ctl: state.relay(ctl), reason: 'observe_mode' };

	switch (ctl.state) {
	case state.TRIALING: return trialing_step(ctl, obs, params, now);
	case state.DIRECT:   return direct_step(ctl, obs, ev, params, now);
	default:             return relay_step(ctl, obs, ev, params, now, steering);
	}
}

function emit(prev, next, obs, ev, res, params, now) {
	let out = [ fx.set_endpoint(next.asserted) ];
	if (next.state == state.RELAY) {
		if (!ev.present)
			push(out, fx.refresh_discovery());
	}
	else if (obs.tunnel_addr) {
		push(out, fx.tunnel_probe(obs.tunnel_addr));
	}
	if (res.resumed != null)
		push(out, fx.resumed(prev.failed_target, res.resumed));
	if (res.reason != null)
		push(out, fx.log(res.reason == 'roam_adopted' ? 'roam' : 'transition', prev.state, next.state, res.reason));
	if (res.reason == 'trial_timeout' && next.given_up_at != null)
		push(out, fx.given_up(next.failed_target, next.failed_trials));
	push(out, fx.metric({ ...next, ready: may_trial(next, ev, params, now) }));
	return out;
}

// The endpoint a trial started on this obs would take: the roam if one was seen, else the candidate.
export function trial_target(ctl, obs) {
	return derive_evidence(ctl, obs).target;
};

export function decide(ctl, obs, params, now) {
	let ev = derive_evidence(ctl, obs);
	let res = step(ctl, obs, ev, params, now);
	let next = { ...res.ctl, asserted: (res.ctl.state == state.RELAY) ? obs.relay_endpoint : res.ctl.target };
	if (next.state != ctl.state)
		next.last_change = { ts: now, from: ctl.state, to: next.state, reason: res.reason };

	return { ctl: next, effects: emit(ctl, next, obs, ev, res, params, now) };
};
