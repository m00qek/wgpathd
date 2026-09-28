'use strict';

// What each probe is: its destination host, echo payload size and the device it must leave by.

import * as endpoint from 'wgpathd.endpoint';
import * as icmp from 'wgpathd.icmp';

export const UNDERLAY_PAYLOAD = 16;

// Only a direct (IPv6) endpoint has an underlay worth probing. It leaves by
// whatever the routes say: it is the path the direct tunnel would take.
export function underlay(direct) {
	if (!endpoint.is_v6(direct))
		return null;
	return { host: endpoint.host(direct), size: UNDERLAY_PAYLOAD, device: null };
};

// Bound to the mesh interface, so a misrouted probe can never leave outside the
// tunnel; and full size, so only a path that carries full-size packets answers.
export function tunnel(addr, mtu, device) {
	let fam = icmp.family(addr);
	if (fam == null)
		return null;
	return { host: endpoint.canonical_ip(addr), size: max(0, mtu - icmp.IP_HEADER[fam] - icmp.ECHO_HEADER), device: device };
};
