'use strict';

// argv builders for the busybox ping probes and their exit-code reading.

import * as endpoint from 'wgpathd.endpoint';

// Lets ping answer for itself before the runner gives up on it.
const BACKSTOP_MARGIN = 0.5;

// busybox ping -W takes whole seconds.
export function wait_seconds(timeout) {
	let w = int(timeout);
	return max(1, (w < timeout) ? w + 1 : w);
};

export function backstop(timeout) {
	return wait_seconds(timeout) + BACKSTOP_MARGIN;
};

// Only a direct (IPv6) endpoint has an underlay worth probing.
export function underlay_command(direct, timeout) {
	if (!endpoint.is_v6(direct))
		return null;
	return [ 'ping', '-6', '-c1', `-W${wait_seconds(timeout)}`, endpoint.host(direct) ];
};

export function tunnel_command(addr, timeout) {
	return [ 'ping', '-c1', `-W${wait_seconds(timeout)}`, addr ];
};

export function reachable(res) {
	return res?.ok === true && res.data?.code === 0;
};
