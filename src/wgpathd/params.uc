'use strict';

// Timing parameters: the design defaults, overridable per option in the `main` section.

export const DEFAULTS = {
	cycle: 3,
	n_up: 5,
	m_down: 2,
	tunnel_timeout: 1,
	trial_window: 8,
	backoff_min: 30,
	backoff_max: 900,
	backoff_reset: 600,
	discovery_interval: 60,
	give_up_after: 3,
	give_up_pause: 21600,
};

// The values a parameter may take. A cycle waits `cycle`, then up to `tunnel_timeout`
// for the underlay probes, the `wg set` limit (2 s), and `tunnel_timeout` again for
// the tunnel probes before it pings procd's watchdog: at the maxima that is 22 of
// its 30 seconds, and the rest is left to the ubus reads.
export const BOUNDS = {
	cycle:              { min: 1,   max: 10 },
	n_up:               { min: 1,   max: 100, whole: true },
	m_down:             { min: 1,   max: 100, whole: true },
	tunnel_timeout:     { min: 0.1, max: 5 },
	trial_window:       { min: 1,   max: 60 },
	backoff_min:        { min: 1,   max: 86400 },
	backoff_max:        { min: 1,   max: 86400 },
	backoff_reset:      { min: 1,   max: 86400 },
	discovery_interval: { min: 5,   max: 86400 },
	give_up_after:      { min: 1,   max: 100, whole: true },
	give_up_pause:      { min: 60,  max: 604800 },
};

export function bounds_text(name) {
	let b = BOUNDS[name];
	return `must be a ${b.whole ? 'whole ' : ''}number from ${b.min} to ${b.max}`;
};

// Decimal digits with an optional fraction, nothing else; null out of bounds.
export function parse(name, s) {
	let b = BOUNDS[name];
	if (type(s) != 'string' || match(s, b.whole ? /^[0-9]+$/ : /^[0-9]+(\.[0-9]+)?$/) == null)
		return null;
	let v = +s;
	return (v >= b.min && v <= b.max) ? v : null;
};

// Returns the parameter in conflict with another, as [ name, what it must be ], or null.
// A trial's first answer is read a cycle and a probe wait after it starts.
export function conflict(p) {
	if (p.backoff_max < p.backoff_min)
		return [ 'backoff_max', `must be at least backoff_min (${p.backoff_min})` ];
	if (p.trial_window <= p.cycle + p.tunnel_timeout)
		return [ 'trial_window', sprintf('must be longer than cycle + tunnel_timeout (%g)', p.cycle + p.tunnel_timeout) ];
	return null;
};

export function build(cfg) {
	return { ...DEFAULTS, ...cfg.overrides, mode: cfg.mode };
};

// The timing values in effect, without the mode.
export function timing(params) {
	let out = {};
	for (let name in keys(DEFAULTS))
		out[name] = params[name];
	return out;
};
