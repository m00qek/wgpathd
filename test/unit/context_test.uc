import { describe, it, assert } from 'utest';
import { with_context } from 'context';

describe('context: with_context', () => {
	it('gives deps a fake clock whose now() and wall() are read back', () => {
		with_context({ clock: { now: 1234.5, wall: 1790000000 } }, (deps) => {
			assert.match(1234.5, deps.clock.now());
			assert.match(1790000000, deps.clock.wall());
		});
	});

	it('advances both clocks together', () => {
		with_context({ clock: { now: 100, wall: 1000 } }, (deps) => {
			deps.clock.advance(5);
			assert.match([ 105, 1005 ], [ deps.clock.now(), deps.clock.wall() ]);
		});
	});

	it('defaults the fake clock to 0', () => {
		with_context({ clock: {} }, (deps) => {
			assert.match([ 0, 0 ], [ deps.clock.now(), deps.clock.wall() ]);
		});
	});

	it('wires only the requested deps plus a no-op log', () => {
		with_context({ clock: {} }, (deps) => {
			assert.match([ 'clock', 'log' ], sort(keys(deps)));
			assert.match(null, deps.log('info', 'ignored'));
		});
	});
});
