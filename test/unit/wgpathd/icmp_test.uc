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

	it('sums to zero over a message that carries its own checksum', () => {
		assert.match(0, icmp.checksum(V4_REQUEST));
		assert.match(0, icmp.checksum(V4_REPLY));
	});

	prop('makes every request it builds check out', gen.tuple(gen.int(0, 65535), gen.int(0, 65535), gen.int(0, 1400)), (t) => {
		assert.match(0, icmp.checksum(icmp.echo_request(4, t[0], t[1], icmp.payload(t[2]))));
	});
});

describe('icmp: echo_request', () => {
	it('builds an IPv4 echo request byte for byte', () => {
		assert.match(V4_REQUEST, icmp.echo_request(4, 0x4242, 7, 'abc'));
	});

	it('leaves the ICMPv6 checksum for the kernel to fill in', () => {
		assert.match(V6_REQUEST, icmp.echo_request(6, 0x4242, 7, 'abc'));
	});

	it('carries a payload of exactly the size asked for', () => {
		for (let size in [ 0, 1, 16, 1332, 8952 ]) {
			assert.match(size, length(icmp.payload(size)));
			assert.match(size + icmp.ECHO_HEADER, length(icmp.echo_request(4, 1, 1, icmp.payload(size))));
		}
	});
});

describe('icmp: parse_reply', () => {
	it('reads an IPv4 reply behind its IP header', () => {
		assert.match({ id: 0x4242, seq: 7, size: 3 }, icmp.parse_reply(4, IP4 + V4_REPLY));
	});

	it('reads an IPv6 reply, which comes without its IP header', () => {
		assert.match({ id: 0x4242, seq: 7, size: 3 }, icmp.parse_reply(6, V6_REPLY));
	});

	it('skips IPv4 options', () => {
		let with_options = bytes('46 00 0023 0000 4000 40 01 0000 7f000001 7f000001 01010100');
		assert.match({ id: 0x4242, seq: 7, size: 3 }, icmp.parse_reply(4, with_options + V4_REPLY));
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

	it('ignores an IPv4 reply whose checksum does not add up', () => {
		assert.match(null, icmp.parse_reply(4, IP4 + bytes('00 00 f953 4242 0007 616264')));
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

describe('icmp: family', () => {
	it('tells IPv4 from IPv6, and neither from anything else', () => {
		assert.match([ 4, 6, null, null, null ], map([ '10.20.0.12', '2001:db8::1', 'wg_mesh', '', null ], icmp.family));
	});
});
