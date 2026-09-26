import { describe, it, prop, gen, assert } from 'utest';
import * as clock from 'wgpathd.components.clock';

describe('components.clock: now()', () => {
	it('asks the clock source for the monotonic clock', () => {
		let asked;
		clock.create((monotonic) => { asked = monotonic; return [ 0, 0 ]; }).now();
		assert.match(true, asked);
	});

	it('converts seconds and nanoseconds to fractional seconds', () => {
		assert.match(5.5, clock.create(() => [ 5, 500000000 ]).now());
	});

	prop('adds the sub-second part to the seconds', gen.tuple(gen.int(0, 1000000), gen.int(0, 999)), (p) => {
		let ms = p[1];
		assert.match(p[0] + ms / 1000.0, clock.create(() => [ p[0], ms * 1000000 ]).now());
	});

	it('defaults to the real monotonic clock, which never goes backwards', () => {
		let c = clock.create();
		let a = c.now();
		let b = c.now();
		assert.match(true, a > 0 && b >= a);
	});
});
