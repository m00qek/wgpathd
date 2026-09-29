'use strict';

// ICMP echo on the wire: the request to send and the reading of a reply, for IPv4 (4) and IPv6 (6).

export const IP_HEADER   = { [4]: 20, [6]: 40 };
export const ECHO_HEADER = 8;

const REQUEST = { [4]: 8, [6]: 128 };
const REPLY   = { [4]: 0, [6]: 129 };
const PROTO_ICMP = 1;

function u16(n) {
	return chr((n >> 8) & 0xff, n & 0xff);
}

function read_u16(s, at) {
	return (ord(s, at) << 8) | ord(s, at + 1);
}

function fold(sum) {
	while (sum > 0xffff)
		sum = (sum & 0xffff) + (sum >> 16);
	return sum;
}

// RFC 1071: the ones' complement sum of the 16-bit words from byte `from` on, before its complement.
export function sum16(bytes, from) {
	let sum = 0;
	let n = length(bytes);
	for (let i = from ?? 0; i < n; i += 2)
		sum += (ord(bytes, i) << 8) | ((i + 1 < n) ? ord(bytes, i + 1) : 0);
	return fold(sum);
};

export function checksum(bytes, from) {
	return ~sum16(bytes, from) & 0xffff;
};

export function family(host) {
	let arr = (type(host) == 'string') ? iptoarr(host) : null;
	return arr ? ((length(arr) == 16) ? 6 : 4) : null;
};

export const NONCE = 8;

export function filler(size) {
	let s = 'wgpathd ';
	while (length(s) < size)
		s += s;
	return substr(s, 0, size);
};

// What the echo requests of a payload size share: the room their nonce takes and
// the filler after it, with its sum. Summing a full-size payload takes milliseconds
// on a router, and a tunnel probe should leave the moment `wg set` returns.
export function echo_payload(size) {
	let nonce = min(size, NONCE);
	let body = filler(size - nonce);
	return { nonce: nonce, body: body, sum: sum16(body) };
};

// A probe's own payload: its nonce, then the filler. The nonce has an even length
// whenever a filler follows it, so the two sums add word for word.
export function with_nonce(payload, nonce) {
	let head = substr(nonce, 0, payload.nonce);
	return { data: head + payload.body, sum: sum16(head) + payload.sum };
};

// The ICMPv6 checksum covers a pseudo-header with the source address, which only the
// kernel knows; on a raw ICMPv6 socket it always fills the checksum in (RFC 3542).
// The payload starts at an even offset, so its sum adds to the header's word for word.
export function echo_request(fam, id, seq, data, data_sum) {
	let sum = 0;
	if (fam == 4)
		sum = ~fold((REQUEST[fam] << 8) + id + seq + (data_sum ?? sum16(data))) & 0xffff;
	return chr(REQUEST[fam], 0) + u16(sum) + u16(id) + u16(seq) + data;
};

// A raw IPv4 socket hands over the IP header as well.
function message_offset(fam, packet) {
	if (fam == 6)
		return 0;
	let header = (ord(packet, 0) & 0x0f) * 4;
	if (length(packet) < IP_HEADER[4] || (ord(packet, 0) >> 4) != 4 || header < IP_HEADER[4] || ord(packet, 9) != PROTO_ICMP)
		return null;
	return header;
}

// Returns { id, seq, size, offset } for what reads as an echo reply, null for anything
// else. Only the header is read: a raw socket sees every ICMP packet, and the checksum,
// a pass over every byte, is left to intact() for a reply that matches a probe.
export function parse_reply(fam, packet) {
	let at = (type(packet) == 'string') ? message_offset(fam, packet) : null;
	if (at == null || length(packet) - at < ECHO_HEADER || ord(packet, at) != REPLY[fam] || ord(packet, at + 1) != 0)
		return null;
	return { id: read_u16(packet, at + 4), seq: read_u16(packet, at + 6), size: length(packet) - at - ECHO_HEADER, offset: at };
};

// The kernel verifies an ICMPv6 checksum before a raw socket sees the message, but not an ICMPv4 one.
export function intact(fam, packet, reply) {
	return fam == 6 || checksum(packet, reply.offset) == 0;
};

export function echoed(packet, reply) {
	return substr(packet, reply.offset + ECHO_HEADER);
};
