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
};

export function build(cfg) {
	return { ...DEFAULTS, ...cfg.overrides, mode: cfg.mode };
};
