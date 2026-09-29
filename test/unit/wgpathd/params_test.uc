import { describe, it, assert } from 'utest';
import * as params from 'wgpathd.params';

describe('params: build', () => {
	it('uses the design defaults and the configured mode', () => {
		assert.match({ cycle: 3, n_up: 5, m_down: 2, tunnel_timeout: 1, trial_window: 8, backoff_min: 30,
			backoff_max: 900, backoff_reset: 600, discovery_interval: 60, mode: 'observe' },
			params.build({ mode: 'observe', overrides: {} }));
	});

	it('lets an override replace its default only', () => {
		let p = params.build({ mode: 'steer', overrides: { cycle: 0.5, backoff_min: 2 } });
		assert.match([ 0.5, 2, 5, 'steer' ], [ p.cycle, p.backoff_min, p.n_up, p.mode ]);
	});
});

describe('params: timing', () => {
	it('keeps the timing values in effect and leaves the mode out', () => {
		let p = params.build({ mode: 'steer', overrides: { m_down: 3 } });
		assert.match({ cycle: 3, n_up: 5, m_down: 3, tunnel_timeout: 1, trial_window: 8, backoff_min: 30,
			backoff_max: 900, backoff_reset: 600, discovery_interval: 60 }, params.timing(p));
	});
});
