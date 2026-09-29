import { describe, it, assert } from 'utest';
import * as params from 'wgpathd.params';

describe('params: build', () => {
	it('uses the design defaults and the configured mode', () => {
		assert.match({ cycle: 3, n_up: 5, m_down: 2, tunnel_timeout: 1, trial_window: 8, backoff_min: 30,
			backoff_max: 900, backoff_reset: 600, discovery_interval: 60, give_up_after: 3, give_up_pause: 21600, mode: 'observe' },
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
			backoff_max: 900, backoff_reset: 600, discovery_interval: 60, give_up_after: 3, give_up_pause: 21600 }, params.timing(p));
	});
});

describe('params: bounds', () => {
	it('bounds every parameter, and holds the defaults within them without conflict', () => {
		assert.match(sort(keys(params.DEFAULTS)), sort(keys(params.BOUNDS)));
		for (let name, v in params.DEFAULTS)
			assert.match(v, params.parse(name, `${v}`), name);
		assert.match(null, params.conflict(params.DEFAULTS));
	});

	// procd restarts a daemon that has not pinged its watchdog for 30 s, and a spoke
	// pings once a cycle: after its pause, two probe waits and the 2 s `wg set` limit.
	it('keeps the longest cycle well within the watchdog', () => {
		let b = params.BOUNDS;
		assert.match(true, b.cycle.max + 2 * b.tunnel_timeout.max + 2 <= 25);
		assert.match(true, b.cycle.min >= 1, 'no cycle runs back to back');
	});

	it('leaves a trial room at the longest cycle and probe wait', () => {
		let b = params.BOUNDS;
		assert.match(true, b.trial_window.max > b.cycle.max + b.tunnel_timeout.max);
	});

	it('reads whole numbers only for a count of cycles', () => {
		assert.match([ 3, null, null ], [ params.parse('n_up', '3'), params.parse('n_up', '3.0'), params.parse('m_down', '2.5') ]);
		assert.match([ 3, null ], [ params.parse('give_up_after', '3'), params.parse('give_up_after', '2.5') ]);
		assert.match([ 2.5, 0.1 ], [ params.parse('cycle', '2.5'), params.parse('tunnel_timeout', '0.1') ]);
	});
});

describe('params: conflict', () => {
	it('names backoff_max below backoff_min, then a trial_window too short', () => {
		let p = params.DEFAULTS;
		assert.match([ 'backoff_max', 'must be at least backoff_min (30)' ], params.conflict({ ...p, backoff_max: 10 }));
		assert.match([ 'trial_window', 'must be longer than cycle + tunnel_timeout (4)' ], params.conflict({ ...p, trial_window: 4 }));
		assert.match('backoff_max', params.conflict({ ...p, backoff_max: 10, trial_window: 1 })[0]);
	});
});
