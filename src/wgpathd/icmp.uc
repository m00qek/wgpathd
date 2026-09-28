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

// RFC 1071: the ones' complement of the ones' complement sum of 16-bit words.
export function checksum(bytes) {
	let sum = 0;
	let n = length(bytes);
	for (let i = 0; i < n; i += 2)
		sum += (ord(bytes, i) << 8) | ((i + 1 < n) ? ord(bytes, i + 1) : 0);
	while (sum > 0xffff)
		sum = (sum & 0xffff) + (sum >> 16);
	return ~sum & 0xffff;
};

export function family(host) {
	let arr = (type(host) == 'string') ? iptoarr(host) : null;
	return arr ? ((length(arr) == 16) ? 6 : 4) : null;
};

export function payload(size) {
	let s = 'wgpathd ';
	while (length(s) < size)
		s += s;
	return substr(s, 0, size);
};

// The ICMPv6 checksum covers a pseudo-header with the source address, which only the
// kernel knows; on a raw ICMPv6 socket it always fills the checksum in (RFC 3542).
export function echo_request(fam, id, seq, data) {
	let head = chr(REQUEST[fam], 0);
	let rest = u16(id) + u16(seq) + data;
	let sum = (fam == 4) ? checksum(head + u16(0) + rest) : 0;
	return head + u16(sum) + rest;
};

// A raw IPv4 socket hands over the IP header as well. The kernel verifies an ICMPv6
// checksum before a raw socket sees the message, but not an ICMPv4 one.
function icmp_message(fam, packet) {
	if (fam == 6)
		return packet;
	let header = (ord(packet, 0) & 0x0f) * 4;
	if (length(packet) < IP_HEADER[4] || (ord(packet, 0) >> 4) != 4 || header < IP_HEADER[4] || ord(packet, 9) != PROTO_ICMP)
		return null;
	let msg = substr(packet, header);
	return (checksum(msg) == 0) ? msg : null;
}

// Returns { id, seq, size } for an echo reply, null for anything else.
export function parse_reply(fam, packet) {
	let msg = (type(packet) == 'string') ? icmp_message(fam, packet) : null;
	if (msg == null || length(msg) < ECHO_HEADER || ord(msg, 0) != REPLY[fam] || ord(msg, 1) != 0)
		return null;
	return { id: read_u16(msg, 4), seq: read_u16(msg, 6), size: length(msg) - ECHO_HEADER };
};
