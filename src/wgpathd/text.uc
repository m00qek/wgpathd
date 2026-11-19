'use strict';

// A string matched as one whole line. Older ucode anchors ^ and $ at the ends of the
// string, newer ucode at every line; a string without a newline reads the same on both.
export function match_line(s, re) {
	return (type(s) == 'string' && index(s, '\n') < 0) ? match(s, re) : null;
};
