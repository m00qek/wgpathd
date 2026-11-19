import { describe, it, assert } from 'utest';
import { match_line } from 'wgpathd.text';

describe('text: match_line', () => {
	it('matches a whole line', () => {
		assert.match([ '42', '42' ], match_line('42', /^([0-9]+)$/));
		assert.match(null, match_line('42x', /^[0-9]+$/));
	});

	it('refuses text with a newline anywhere, whatever the pattern', () => {
		for (let s in [ '42\n', '\n42', '42\nx', 'x\n42', '\n' ])
			assert.match(null, match_line(s, /[0-9]*/), s);
	});

	it('refuses non-strings', () => {
		for (let v in [ null, 42, [ '42' ], { s: '42' } ])
			assert.match(null, match_line(v, /.*/));
	});
});
