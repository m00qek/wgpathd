'use strict';

// The `wg set` argv builder and the reader of rpcd's `wireguard status` reply.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import { canonical } from 'wgpathd.endpoint';

export function is_pubkey(s) {
	return type(s) == 'string' && match(s, /^[A-Za-z0-9+\/]{43}=$/) != null;
};

// One command for every peer: sets: [ { pubkey, endpoint } ].
export function set_endpoints_command(iface, sets) {
	let argv = [ 'wg', 'set', iface ];
	for (let s in sets)
		push(argv, 'peer', s.pubkey, 'endpoint', s.endpoint);
	return argv;
};

function parse_peer(value) {
	if (type(value) != 'object' || type(value.last_handshake) != 'int' || value.last_handshake < 0)
		return null;
	let hs = value.last_handshake;
	return { endpoint: canonical(value.endpoint), last_hs_ts: hs ? hs : null };
}

// An endpoint we cannot canonicalize (e.g. scoped link-local) reads as none, which
// decide never treats as a roam.
export function parse_status(reply, iface) {
	let status = (type(reply) == 'object') ? reply[iface] : null;
	if (type(status) != 'object')
		return Result.err(errors.WG_PARSE_FAILED, `no interface ${iface}`);
	if (type(status.peers) != 'object')
		return Result.err(errors.WG_PARSE_FAILED, 'no peer table');

	let peers = {};
	for (let key, value in status.peers) {
		let peer = is_pubkey(key) ? parse_peer(value) : null;
		if (peer == null)
			return Result.err(errors.WG_PARSE_FAILED, 'invalid peer entry');
		peers[key] = peer;
	}
	return Result.ok(peers);
};
