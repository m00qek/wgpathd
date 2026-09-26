import { describe, it, prop, gen, assert } from 'utest';
import * as endpoint from 'wgpathd.endpoint';

const V6_BYTES = gen.array(gen.int(0, 255), { len: 16 });
const V4_BYTES = gen.array(gen.int(0, 255), { len: 4 });
const PORT     = gen.int(1, 65535);
const NOISE    = gen.string({ max_len: 40, charset: '0123456789abcdefABCDEF:.[]% ' });

// Fully expanded, uppercase, zero-padded: valid but never how wg prints it.
function expanded_v6(bytes) {
	let groups = [];
	for (let i = 0; i < 16; i += 2)
		push(groups, sprintf('%04X', bytes[i] * 256 + bytes[i + 1]));
	return join(':', groups);
}

describe('endpoint: canonical', () => {
	it('keeps an already canonical endpoint as is', () => {
		assert.match('[2001:db8::1]:51820', endpoint.canonical('[2001:db8::1]:51820'));
		assert.match('10.10.0.12:51820', endpoint.canonical('10.10.0.12:51820'));
	});

	it('lowercases and compresses IPv6 the way wg prints it', () => {
		assert.match('[fd42:7770:1::3]:51820', endpoint.canonical('[FD42:7770:0001:0000:0000:0000:0000:0003]:51820'));
		assert.match('[::1]:1', endpoint.canonical('[0:0:0:0:0:0:0:1]:1'));
	});

	it('drops leading zeros from the port', () => {
		assert.match('10.0.0.1:80', endpoint.canonical('10.0.0.1:0080'));
	});

	it('accepts the port bounds and rejects outside them', () => {
		assert.match('10.0.0.1:1', endpoint.canonical('10.0.0.1:1'));
		assert.match('10.0.0.1:65535', endpoint.canonical('10.0.0.1:65535'));
		assert.match(null, endpoint.canonical('10.0.0.1:0'));
		assert.match(null, endpoint.canonical('10.0.0.1:65536'));
		assert.match(null, endpoint.canonical('10.0.0.1:123456'));
	});

	it('rejects malformed endpoints', () => {
		for (let s in [ '', '10.0.0.1', '10.0.0.1:', ':51820', '2001:db8::1:51820', '[2001:db8::1]',
			'[10.0.0.1]:51820', '[2001:db8::1]:x', '10.0.0.256:1', '01.2.3.4:1', 'host:51820',
			' 10.0.0.1:1', '10.0.0.1:1 ', '[fe80::1%wg0]:51820', '(none)', '10.0.0.1:-1' ])
			assert.match(null, endpoint.canonical(s), s);
	});

	it('rejects non-strings', () => {
		for (let v in [ null, 51820, [ '10.0.0.1:1' ], { host: '10.0.0.1' } ])
			assert.match(null, endpoint.canonical(v));
	});

	prop('renders any IPv6 endpoint as [arrtoip]:port', gen.tuple(V6_BYTES, PORT), (p) => {
		let want = `[${arrtoip(p[0])}]:${p[1]}`;
		assert.match(want, endpoint.canonical(`[${expanded_v6(p[0])}]:${p[1]}`));
		assert.match(want, endpoint.canonical(want));
	});

	prop('renders any IPv4 endpoint as arrtoip:port', gen.tuple(V4_BYTES, PORT), (p) => {
		let want = `${join('.', p[0])}:${p[1]}`;
		assert.match(want, endpoint.canonical(want));
	});

	prop('is idempotent on any input', NOISE, (s) => {
		let once = endpoint.canonical(s);
		if (once != null)
			assert.match(once, endpoint.canonical(once));
	});
});

describe('endpoint: canonical_ip', () => {
	it('canonicalizes a bare address', () => {
		assert.match('fd42:7770:1::3', endpoint.canonical_ip('FD42:7770:1:0::3'));
		assert.match('10.20.0.12', endpoint.canonical_ip('10.20.0.12'));
	});

	it('rejects anything that is not a bare address', () => {
		for (let v in [ null, '', '10.20.0.12:51820', '[::1]', 'wg_mesh', '10.0.0.0/8' ])
			assert.match(null, endpoint.canonical_ip(v));
	});
});

describe('endpoint: is_v6 and host', () => {
	it('tells IPv6 endpoints from IPv4 ones', () => {
		assert.match(true, endpoint.is_v6('[2001:db8::1]:51820'));
		assert.match(false, endpoint.is_v6('10.0.0.1:51820'));
		assert.match(false, endpoint.is_v6('garbage'));
	});

	it('returns the canonical host without brackets or port', () => {
		assert.match('2001:db8::1', endpoint.host('[2001:DB8:0::1]:51820'));
		assert.match('10.0.0.1', endpoint.host('10.0.0.1:51820'));
		assert.match(null, endpoint.host('10.0.0.1'));
	});

	prop('host of an IPv6 endpoint is its canonical address', gen.tuple(V6_BYTES, PORT), (p) => {
		assert.match(arrtoip(p[0]), endpoint.host(`[${expanded_v6(p[0])}]:${p[1]}`));
	});
});
