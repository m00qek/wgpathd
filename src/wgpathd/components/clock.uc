'use strict';

// Monotonic clock in seconds; the shell reads it and passes `now` to decide.

export function create(clock_fn) {
	clock_fn = clock_fn || clock;

	return {
		now: function() {
			let ts = clock_fn(true);
			return ts[0] + ts[1] / 1e9;
		}
	};
};
