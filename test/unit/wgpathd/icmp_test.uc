import { describe, it, prop, gen, assert } from 'utest';
import * as icmp from 'wgpathd.icmp';

function bytes(digits) {
	digits = replace(digits, / /g, '');
	let out = '';
	for (let i = 0; i < length(digits); i += 2)
		out += chr(hex(substr(digits, i, 2)));
	return out;
}

// Captured on the loopback of the OpenWrt 25.12.5 rootfs, from raw sockets: echo id
// 0x4242, sequence 7, payload "abc".
const V4_REQUEST = bytes('08 00 f153 4242 0007 616263');
const V4_REPLY   = bytes('00 00 f953 4242 0007 616263');
const V6_REQUEST = bytes('80 00 0000 4242 0007 616263');
const V6_REPLY   = bytes('81 00 780c 4242 0007 616263');
// An IPv4 header as a raw socket hands it over: version 4, 20 bytes, protocol 1 (ICMP).
const IP4 = bytes('45 00 001f 0000 4000 40 01 0000 7f000001 7f000001');

describe('icmp: checksum', () => {
	it('matches the worked example of RFC 1071', () => {
		assert.match(0x220d, icmp.checksum(bytes('0001 f203 f4f5 f6f7')));
	});

	// By hand: 0x0800 + 0x4242 + 0x0007 + 0x6162 + 0x6300 (the odd byte padded with
	// zero) = 0x10eab; folding the carry gives 0x0eac, whose complement is 0xf153.
	it('matches the checksum the kernel accepted in a captured request', () => {
		assert.match(0xf153, icmp.checksum(bytes('08 00 0000 4242 0007 616263')));
	});

	it('sums from an offset, as if the bytes before it were not there', () => {
		assert.match(0x220d, icmp.checksum(bytes('ffff ff 0001 f203 f4f5 f6f7'), 3));
	});

	it('sums to zero over a message that carries its own checksum', () => {
		assert.match(0, icmp.checksum(V4_REQUEST));
		assert.match(0, icmp.checksum(V4_REPLY));
	});

	prop('makes every request it builds check out', gen.tuple(gen.int(0, 65535), gen.int(0, 65535), gen.int(0, 1400)), (t) => {
		assert.match(0, icmp.checksum(icmp.echo_request(4, t[0], t[1], icmp.filler(t[2]))));
	});
});

describe('icmp: echo_request', () => {
	it('builds an IPv4 echo request byte for byte', () => {
		assert.match(V4_REQUEST, icmp.echo_request(4, 0x4242, 7, 'abc'));
	});

	it('leaves the ICMPv6 checksum for the kernel to fill in', () => {
		assert.match(V6_REQUEST, icmp.echo_request(6, 0x4242, 7, 'abc'));
	});

	it('builds the captured request from a kept sum', () => {
		assert.match(V4_REQUEST, icmp.echo_request(4, 0x4242, 7, 'abc', icmp.sum16('abc')));
	});

	it('carries a payload of exactly the size asked for', () => {
		for (let size in [ 0, 1, 16, 1332, 8952 ])
			assert.match(size + icmp.ECHO_HEADER, length(icmp.echo_request(4, 1, 1, icmp.filler(size))));
	});
});

const NONCE = bytes('0102 0304 0506 0708');

describe('icmp: payload with a nonce', () => {
	it('puts the nonce first and fills the rest', () => {
		assert.match(NONCE + 'wgpathd ', icmp.with_nonce(icmp.echo_payload(16), NONCE).data);
	});

	// By hand: 0x0800 + 0x4242 + 0x0007, the nonce 0x0102 + 0x0304 + 0x0506 + 0x0708 and
	// "wgpathd " 0x7767 + 0x7061 + 0x7468 + 0x6420 add to 0x21aad; folding the carries
	// gives 0x1aaf, whose complement is 0xe550.
	it('builds an IPv4 request byte for byte from the kept sum and the nonce', () => {
		let p = icmp.with_nonce(icmp.echo_payload(16), NONCE);
		assert.match(bytes('08 00 e550 4242 0007 0102030405060708 7767706174686420'), icmp.echo_request(4, 0x4242, 7, p.data, p.sum));
		assert.match(bytes('80 00 0000 4242 0007 0102030405060708 7767706174686420'), icmp.echo_request(6, 0x4242, 7, p.data, p.sum));
	});

	it('cuts the nonce to a payload it does not fit, odd sizes included', () => {
		let p = icmp.with_nonce(icmp.echo_payload(3), NONCE);
		assert.match(bytes('010203'), p.data);
		assert.match(bytes('08 00 b1b4 4242 0007 010203'), icmp.echo_request(4, 0x4242, 7, p.data, p.sum));
		assert.match('', icmp.with_nonce(icmp.echo_payload(0), NONCE).data);
	});

	it('takes no more of the random bytes than a nonce', () => {
		assert.match(NONCE + 'wgpathd ', icmp.with_nonce(icmp.echo_payload(16), NONCE + 'more').data);
	});

	prop('is exactly the size asked for', gen.int(0, 9000), (size) => {
		assert.match(size, length(icmp.with_nonce(icmp.echo_payload(size), NONCE).data));
	});

	prop('keeps a sum that builds the same bytes as summing the whole payload',
		gen.tuple(gen.int(0, 65535), gen.int(0, 65535), gen.int(0, 1400), gen.array(gen.int(0, 255), { len: 8 })), (t) => {
		let p = icmp.with_nonce(icmp.echo_payload(t[2]), join('', map(t[3], (b) => chr(b))));
		for (let fam in [ 4, 6 ])
			assert.match(icmp.echo_request(fam, t[0], t[1], p.data), icmp.echo_request(fam, t[0], t[1], p.data, p.sum));
		assert.match(0, icmp.checksum(icmp.echo_request(4, t[0], t[1], p.data, p.sum)));
	});
});

describe('icmp: echoed', () => {
	it('is the payload of a reply, behind the headers', () => {
		assert.match([ 'abc', 'abc' ], [ icmp.echoed(IP4 + V4_REPLY, icmp.parse_reply(4, IP4 + V4_REPLY)),
			icmp.echoed(V6_REPLY, icmp.parse_reply(6, V6_REPLY)) ]);
	});
});

describe('icmp: parse_reply', () => {
	it('reads an IPv4 reply behind its IP header', () => {
		assert.match({ id: 0x4242, seq: 7, size: 3, offset: 20 }, icmp.parse_reply(4, IP4 + V4_REPLY));
	});

	it('reads an IPv6 reply, which comes without its IP header', () => {
		assert.match({ id: 0x4242, seq: 7, size: 3, offset: 0 }, icmp.parse_reply(6, V6_REPLY));
	});

	it('skips IPv4 options', () => {
		let with_options = bytes('46 00 0023 0000 4000 40 01 0000 7f000001 7f000001 01010100');
		assert.match({ id: 0x4242, seq: 7, size: 3, offset: 24 }, icmp.parse_reply(4, with_options + V4_REPLY));
	});

	it('ignores anything but an echo reply', () => {
		assert.match(null, icmp.parse_reply(4, IP4 + V4_REQUEST));
		assert.match(null, icmp.parse_reply(6, V6_REQUEST));
		let unreachable = bytes('03 01 fcfe 00000000') + IP4;
		assert.match(null, icmp.parse_reply(4, IP4 + unreachable));
		assert.match(null, icmp.parse_reply(6, bytes('01 04 0000 00000000')));
		assert.match(null, icmp.parse_reply(6, bytes('81 01 0000 4242 0007')), 'a reply with a nonzero code');
	});

	it('ignores a reply of the other family', () => {
		assert.match(null, icmp.parse_reply(6, V4_REPLY));
		assert.match(null, icmp.parse_reply(4, V6_REPLY));
	});

	it('ignores a truncated packet', () => {
		assert.match(null, icmp.parse_reply(4, substr(IP4, 0, 12)));
		assert.match(null, icmp.parse_reply(4, IP4 + substr(V4_REPLY, 0, 7)));
		assert.match(null, icmp.parse_reply(6, substr(V6_REPLY, 0, 7)));
		assert.match(null, icmp.parse_reply(4, ''));
		assert.match(null, icmp.parse_reply(6, ''));
	});

	it('reads the header alone, leaving the checksum to intact', () => {
		let corrupted = IP4 + bytes('00 00 f953 4242 0007 616264');
		assert.match({ id: 0x4242, seq: 7, size: 3, offset: 20 }, icmp.parse_reply(4, corrupted));
		assert.match(null, icmp.parse_reply(4, IP4 + bytes('08 00 0000 4242 0007 616263')), 'a request, whatever its checksum');
	});

	it('ignores an IPv4 packet that is not ICMP or not IPv4', () => {
		assert.match(null, icmp.parse_reply(4, bytes('45 00 001f 0000 4000 40 11 0000 7f000001 7f000001') + V4_REPLY));
		assert.match(null, icmp.parse_reply(4, bytes('65 00 001f 0000 4000 40 01 0000 7f000001 7f000001') + V4_REPLY));
		assert.match(null, icmp.parse_reply(4, bytes('44 00 001f 0000 4000 40 01 0000 7f000001 7f000001') + V4_REPLY));
	});

	it('ignores what is not a packet', () => {
		assert.match(null, icmp.parse_reply(4, null));
		assert.match(null, icmp.parse_reply(6, 42));
	});
});

describe('icmp: intact', () => {
	it('checks the ICMPv4 checksum of a reply behind its IP header', () => {
		let good = IP4 + V4_REPLY;
		let bad = IP4 + bytes('00 00 f953 4242 0007 616264');
		assert.match([ true, false ], map([ good, bad ], (p) => icmp.intact(4, p, icmp.parse_reply(4, p))));
	});

	it('leaves the ICMPv6 checksum to the kernel, which has verified it', () => {
		let bad = bytes('81 00 0000 4242 0007 616263');
		assert.match(true, icmp.intact(6, bad, icmp.parse_reply(6, bad)));
	});
});

describe('icmp: family', () => {
	it('tells IPv4 from IPv6, and neither from anything else', () => {
		assert.match([ 4, 6, null, null, null ], map([ '10.20.0.12', '2001:db8::1', 'wg_mesh', '', null ], icmp.family));
	});
});
