'use strict';

// Relay loop guard: a managed peer's relay host must not be routed into mesh_iface.

import * as Result from 'wgpathd.result';
import * as endpoint from 'wgpathd.endpoint';

export const MANAGED  = 'managed';
export const REJECTED = 'rejected';
export const PENDING  = 'pending';

// REJECTED is a configuration error and final; PENDING is a failed lookup (wg_hub
// not up yet at boot) and is worth retrying.
export function guard(route_get, mesh_iface, peer) {
	let res = route_get(endpoint.host(peer.relay));
	if (!res.ok)
		return { verdict: PENDING, reason: `relay route lookup failed: ${Result.describe(res)}` };
	if (res.data.oif == mesh_iface)
		return { verdict: REJECTED, reason: `relay routes into ${mesh_iface}` };
	return { verdict: MANAGED, oif: res.data.oif };
};
