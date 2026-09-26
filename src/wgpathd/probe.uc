'use strict';

// argv builders for the busybox ping probes and their exit-code reading.

import * as endpoint from 'wgpathd.endpoint';

// Only a direct (IPv6) endpoint has an underlay worth probing.
export function underlay_command(direct) {
	return endpoint.is_v6(direct) ? [ 'ping', '-6', '-c1', '-W1', endpoint.host(direct) ] : null;
};

export function tunnel_command(addr) {
	return [ 'ping', '-c1', '-W1', addr ];
};

export function reachable(res) {
	return res?.ok === true && res.data?.code === 0;
};
