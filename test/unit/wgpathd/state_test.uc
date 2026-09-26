import { describe, it, prop, gen, assert } from 'utest';
import * as state from 'wgpathd.state';

const P = { n_up: 3, backoff_min: 30, backoff_max: 900, backoff_reset: 600 };

describe('state: init', () => {
	it('starts in RELAY with nothing earned', () => {
		assert.match({
			state: state.RELAY,
			up_streak: 0,
			down_streak: 0,
			trial_deadline: null,
			backoff_until: 0,
			backoff: 0,
			direct_since: null,
			target: null,
			asserted: null,
			last_change: null,
		}, state.init());
	});

	it('returns a fresh ctl on every call', () => {
		let a = state.init();
		a.state = state.DIRECT;
		assert.match(state.RELAY, state.init().state);
	});
});

describe('state: entering a state', () => {
	const busy = { ...state.init(), state: state.DIRECT, up_streak: 4, down_streak: 1,
		trial_deadline: 5.5, direct_since: 10.25, target: '[2001:db8::1]:51820', backoff: 60, asserted: 'x' };

	it('relay clears the target, deadline, direct_since and streaks', () => {
		let c = state.relay(busy);
		assert.match(state.RELAY, c.state);
		assert.match([ 0, 0 ], [ c.up_streak, c.down_streak ]);
		assert.match([ null, null, null ], [ c.target, c.trial_deadline, c.direct_since ]);
	});

	it('trialing records the target and deadline', () => {
		let c = state.trialing(state.init(), '[2001:db8::2]:51820', 108.5);
		assert.match(state.TRIALING, c.state);
		assert.match('[2001:db8::2]:51820', c.target);
		assert.match(108.5, c.trial_deadline);
		assert.match([ 0, 0 ], [ c.up_streak, c.down_streak ]);
	});

	it('direct keeps the target and records when it began', () => {
		let c = state.direct(state.trialing(state.init(), 't', 108.5), 103.5);
		assert.match(state.DIRECT, c.state);
		assert.match('t', c.target);
		assert.match(103.5, c.direct_since);
		assert.match(null, c.trial_deadline);
	});

	it('keeps backoff and asserted across transitions', () => {
		let c = state.relay(busy);
		assert.match([ 60, 'x' ], [ c.backoff, c.asserted ]);
	});

	it('does not mutate its input', () => {
		let before = sprintf('%J', busy);
		state.relay(busy);
		state.direct(busy, 1.5);
		state.trialing(busy, 'y', 2.5);
		assert.match(before, sprintf('%J', busy));
	});
});

describe('state: backoff', () => {
	it('first bump starts at backoff_min', () => {
		let c = state.bump_backoff(state.init(), P, 100.5);
		assert.match(30, c.backoff);
		assert.match(130.5, c.backoff_until);
	});

	it('doubles on each further bump', () => {
		let c = state.bump_backoff({ ...state.init(), backoff: 60 }, P, 100.5);
		assert.match(120, c.backoff);
		assert.match(220.5, c.backoff_until);
	});

	it('caps at backoff_max', () => {
		let c = state.bump_backoff({ ...state.init(), backoff: 600 }, P, 0.5);
		assert.match(900, c.backoff);
		assert.match(900, state.bump_backoff(c, P, 0.5).backoff);
	});

	prop('never exceeds backoff_max nor drops below backoff_min', gen.int(0, 20), (n) => {
		let c = state.init();
		for (let i = 0; i < n; i++)
			c = state.bump_backoff(c, P, 1.5);
		assert.match(true, n == 0 || (c.backoff >= P.backoff_min && c.backoff <= P.backoff_max));
	});

	it('settle resets backoff once DIRECT has held for backoff_reset', () => {
		let c = { ...state.direct(state.init(), 100.5), backoff: 120 };
		assert.match(120, state.settle_backoff(c, P, 700.25).backoff);
		assert.match(0, state.settle_backoff(c, P, 700.5).backoff);
	});
});

describe('state: ready', () => {
	it('is ready once up_streak reaches n_up', () => {
		assert.match(false, state.is_ready({ ...state.init(), up_streak: 2 }, P));
		assert.match(true, state.is_ready({ ...state.init(), up_streak: 3 }, P));
		assert.match(true, state.is_ready({ ...state.init(), up_streak: 7 }, P));
	});
});
