'use strict';

// Direct candidate guard: a candidate whose address could be a direct path
// (address.can_be_direct), but that this router must not take as one for this peer.

import * as endpoint from 'wgpathd.endpoint';

// Returns why the candidate is refused, or null. A failed route lookup refuses
// nothing: without a route, the probes cannot leave at all, let alone into the mesh.
export function refusal(route_get, cfg, peer, direct) {
	let host = endpoint.host(direct);
	if (host == endpoint.host(peer.relay))
		return 'relay address';
	if (host == peer.tunnel)
		return 'tunnel address';
	let route = route_get(host);
	if (!route.ok)
		return null;
	if (route.data.local)
		return 'own address';
	if (route.data.oif in [ cfg.mesh_iface, cfg.hub_iface ])
		return `routes into ${route.data.oif}`;
	return null;
};
