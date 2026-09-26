'use strict';

// Per-peer control state (ctl) and the pure helpers decide uses to move it.

export const RELAY    = 'RELAY';
export const TRIALING = 'TRIALING';
export const DIRECT   = 'DIRECT';

export function init() {
	return {
		state: RELAY,
		up_streak: 0,
		down_streak: 0,
		trial_deadline: null,
		backoff_until: 0,
		backoff: 0,
		direct_since: null,
		target: null,
		asserted: null,
		last_change: null,
	};
};

export function relay(ctl) {
	return { ...ctl, state: RELAY, up_streak: 0, down_streak: 0,
		trial_deadline: null, direct_since: null, target: null };
};

export function trialing(ctl, target, deadline) {
	return { ...ctl, state: TRIALING, up_streak: 0, down_streak: 0,
		trial_deadline: deadline, target: target };
};

export function direct(ctl, now) {
	return { ...ctl, state: DIRECT, up_streak: 0, down_streak: 0,
		trial_deadline: null, direct_since: now };
};

export function bump_backoff(ctl, params, now) {
	let backoff = ctl.backoff ? min(2 * ctl.backoff, params.backoff_max) : params.backoff_min;
	return { ...ctl, backoff: backoff, backoff_until: now + backoff };
};

export function settle_backoff(ctl, params, now) {
	return (now - ctl.direct_since >= params.backoff_reset) ? { ...ctl, backoff: 0 } : ctl;
};

export function is_ready(ctl, params) {
	return ctl.up_streak >= params.n_up;
};
