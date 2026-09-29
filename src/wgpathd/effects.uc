'use strict';

// The closed effect vocabulary decide may emit: the scope boundary by construction.

import { RELAY, TRIALING, DIRECT } from 'wgpathd.state';

const STATES  = [ RELAY, TRIALING, DIRECT ];
const EVENTS  = [ 'transition', 'roam' ];
const REASONS = [ 'trial_start', 'trial_ok', 'trial_timeout', 'demoted', 'observe_mode', 'roam_adopted' ];
const RESUME_REASONS = [ 'new_candidate', 'roam', 'pause_over' ];

export function set_endpoint(addr) {
	return { set_endpoint: addr };
};

export function tunnel_probe(addr) {
	return { tunnel_probe: addr };
};

export function refresh_discovery() {
	return { refresh_discovery: true };
};

export function log(event, from, to, reason) {
	return { log: { event: event, from: from, to: to, reason: reason } };
};

export function given_up(endpoint, failed_trials) {
	return { given_up: { endpoint: endpoint, failed_trials: failed_trials } };
};

export function resumed(endpoint, reason) {
	return { resumed: { endpoint: endpoint, reason: reason } };
};

export function metric(m) {
	return { metric: { state: m.state, up_streak: m.up_streak, down_streak: m.down_streak,
		backoff: m.backoff, ready: m.ready } };
};

function is_address(v) {
	return type(v) == 'string' && length(v) > 0;
}

function is_count(v) {
	return type(v) == 'int' && v >= 0;
}

function has_exactly(obj, fields) {
	return type(obj) == 'object' && length(keys(obj)) == length(fields)
		&& length(filter(fields, (f) => exists(obj, f))) == length(fields);
}

const CHECKS = {
	set_endpoint: is_address,
	tunnel_probe: is_address,
	refresh_discovery: (v) => v === true,
	log: (v) => has_exactly(v, [ 'event', 'from', 'to', 'reason' ])
		&& (v.event in EVENTS) && (v.from in STATES) && (v.to in STATES) && (v.reason in REASONS),
	given_up: (v) => has_exactly(v, [ 'endpoint', 'failed_trials' ])
		&& is_address(v.endpoint) && is_count(v.failed_trials) && v.failed_trials >= 1,
	resumed: (v) => has_exactly(v, [ 'endpoint', 'reason' ]) && is_address(v.endpoint) && (v.reason in RESUME_REASONS),
	metric: (v) => has_exactly(v, [ 'state', 'up_streak', 'down_streak', 'backoff', 'ready' ])
		&& (v.state in STATES) && is_count(v.up_streak) && is_count(v.down_streak)
		&& type(v.backoff) in [ 'int', 'double' ] && v.backoff >= 0 && type(v.ready) == 'bool',
};

function is_effect(e) {
	if (type(e) != 'object' || length(keys(e)) != 1)
		return false;
	let kind = keys(e)[0];
	return exists(CHECKS, kind) && CHECKS[kind](e[kind]);
}

export function validate(effects) {
	return type(effects) == 'array' && length(filter(effects, is_effect)) == length(effects);
};
