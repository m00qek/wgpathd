'use strict';

// The special-purpose ranges an IP address may lie in: they decide where the hub may
// listen and what a spoke takes as a direct endpoint.

export const UNSPECIFIED     = 'unspecified';
export const LOOPBACK        = 'loopback';
export const LINK_LOCAL      = 'link-local';
export const MULTICAST       = 'multicast';
export const BROADCAST       = 'broadcast';
export const IPV4_MAPPED     = 'ipv4-mapped';
export const IPV4_COMPATIBLE = 'ipv4-compatible';
export const NAT64           = 'nat64';
export const DISCARD_ONLY    = 'discard-only';
export const UNICAST         = 'unicast';

// The first range an address lies in names it, so a narrower range comes first.
const RANGES = {
	[4]: [
		[ '0.0.0.0', 8, UNSPECIFIED ],
		[ '127.0.0.0', 8, LOOPBACK ],
		[ '169.254.0.0', 16, LINK_LOCAL ],
		[ '224.0.0.0', 4, MULTICAST ],
		[ '255.255.255.255', 32, BROADCAST ],
	],
	[16]: [
		[ '::', 128, UNSPECIFIED ],
		[ '::1', 128, LOOPBACK ],
		[ '::ffff:0:0', 96, IPV4_MAPPED ],
		[ '::', 96, IPV4_COMPATIBLE ],
		[ '64:ff9b::', 96, NAT64 ],
		[ '64:ff9b:1::', 48, NAT64 ],
		[ '100::', 64, DISCARD_ONLY ],
		[ 'fe80::', 10, LINK_LOCAL ],
		[ 'ff00::', 8, MULTICAST ],
	],
};

function within(addr, prefix, bits) {
	for (let i = 0; bits > 0; i++, bits -= 8) {
		let mask = (bits >= 8) ? 0xff : (0xff << (8 - bits)) & 0xff;
		if ((addr[i] & mask) != (prefix[i] & mask))
			return false;
	}
	return true;
}

// Returns null for what is not a literal address, UNICAST for one in no special range.
export function kind(ip) {
	let addr = (type(ip) == 'string') ? iptoarr(ip) : null;
	if (addr == null)
		return null;
	for (let range in RANGES[length(addr)])
		if (within(addr, iptoarr(range[0]), range[1]))
			return range[2];
	return UNICAST;
};

export function is_v6(ip) {
	return type(ip) == 'string' && length(iptoarr(ip) ?? []) == 16;
};

// A listener needs one address of the router's own. An IPv6 link-local address
// is left out because it needs a zone, which the address alone does not carry.
export function can_listen(ip) {
	let k = kind(ip);
	if (k == null || k in [ UNSPECIFIED, MULTICAST, BROADCAST ])
		return false;
	return !(is_v6(ip) && k == LINK_LOCAL);
};

// A direct path crosses the internet or a private network, over IPv6: unique local
// addresses are as good as global ones, but no address that stays on the router, on
// one link, or leads to IPv4 in disguise.
export function can_be_direct(ip) {
	return is_v6(ip) && kind(ip) == UNICAST;
};
