'use strict';

// argv builders for `wg` and the `wg show <iface> dump` parser.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import { canonical } from 'wgpathd.endpoint';

const PEER_FIELDS = 8;

export function is_pubkey(s) {
	return type(s) == 'string' && match(s, /^[A-Za-z0-9+\/]{43}=$/) != null;
};

export function dump_command(iface) {
	return [ 'wg', 'show', iface, 'dump' ];
};

export function set_endpoint_command(iface, pubkey, endpoint) {
	return [ 'wg', 'set', iface, 'peer', pubkey, 'endpoint', endpoint ];
};

// An endpoint wg prints but we cannot canonicalize (e.g. scoped link-local) reads as
// none, which decide never treats as a roam.
function parse_peer(line) {
	let f = split(line, '\t');
	if (length(f) != PEER_FIELDS || !is_pubkey(f[0]) || match(f[4], /^[0-9]+$/) == null)
		return null;
	let hs = +f[4];
	return { pubkey: f[0], endpoint: canonical(f[2]), last_hs_ts: hs ? hs : null };
}

// Line 1 is the interface and holds the private key: it is skipped unread.
export function parse_dump(stdout) {
	let lines = (type(stdout) == 'string') ? split(rtrim(stdout, '\n'), '\n') : [];
	if (length(lines) == 0 || lines[0] == '')
		return Result.err(errors.WG_PARSE_FAILED, 'no interface line');

	let peers = {};
	for (let i = 1; i < length(lines); i++) {
		let peer = parse_peer(lines[i]);
		if (peer == null)
			return Result.err(errors.WG_PARSE_FAILED, `line ${i + 1}`);
		peers[peer.pubkey] = { endpoint: peer.endpoint, last_hs_ts: peer.last_hs_ts };
	}
	return Result.ok(peers);
};
