'use strict';

// Monotonic clock in seconds for decide, plus wall-clock seconds for handshake ages and status.

export function create(clock_fn) {
	clock_fn = clock_fn || clock;

	return {
		now: function() {
			let ts = clock_fn(true);
			return ts[0] + ts[1] / 1e9;
		},
		wall: function() {
			return time();
		}
	};
};
