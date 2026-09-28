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

// Relay traffic from the peer roams the kernel back onto the relay, so the probe may
// have left and come back that way: only an answer that arrived direct proves the path (R4).
function proven(obs) {
	return obs.tunnel_ok === true && obs.answered_via != null && obs.answered_via != obs.relay_endpoint;
}

function relay_step(ctl, obs, ev, params, now, steering) {
	let next = { ...ctl, up_streak: ev.present ? ctl.up_streak + 1 : 0 };
	if (steering && obs.tunnel_addr && is_ready(next, ev, params) && now >= ctl.backoff_until)
		return { ctl: state.trialing(next, ev.target, now + params.trial_window), reason: 'trial_start' };
	return { ctl: next, reason: null };
}

// The deadline is checked first: an answer we cannot place before it does not commit.
function trialing_step(ctl, obs, params, now) {
	if (now >= ctl.trial_deadline)
		return { ctl: state.relay(state.bump_backoff(ctl, params, now)), reason: 'trial_timeout' };
	if (proven(obs))
		return { ctl: state.direct(ctl, now), reason: 'trial_ok' };
	return { ctl: ctl, reason: null };
}

function direct_step(ctl, obs, ev, params, now) {
	let down = proven(obs) ? 0 : ctl.down_streak + 1;
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

function emit(prev, next, obs, ev, reason, params) {
	let out = [ fx.set_endpoint(next.asserted) ];
	if (next.state == state.RELAY) {
		if (!ev.present)
			push(out, fx.refresh_discovery());
	}
	else if (obs.tunnel_addr) {
		push(out, fx.tunnel_probe(obs.tunnel_addr));
	}
	if (reason != null)
		push(out, fx.log(reason == 'roam_adopted' ? 'roam' : 'transition', prev.state, next.state, reason));
	push(out, fx.metric({ ...next, ready: is_ready(next, ev, params) }));
	return out;
}

export function decide(ctl, obs, params, now) {
	let ev = derive_evidence(ctl, obs);
	let res = step(ctl, obs, ev, params, now);
	let next = { ...res.ctl, asserted: (res.ctl.state == state.RELAY) ? obs.relay_endpoint : res.ctl.target };
	if (next.state != ctl.state)
		next.last_change = { ts: now, from: ctl.state, to: next.state, reason: res.reason };

	return { ctl: next, effects: emit(ctl, next, obs, ev, res.reason, params) };
};
