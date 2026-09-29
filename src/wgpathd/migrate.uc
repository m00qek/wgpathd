'use strict';

// Moves the peer settings of releases up to 4, options wgpathd_relay and wgpathd_tunnel
// of WireGuard peer sections in /etc/config/network, into `peer` sections of
// /etc/config/wgpathd keyed by public key. A value /etc/config/wgpathd already holds is
// kept. wgpathd is committed before network is touched, so a failure loses nothing and
// running it again finishes the job.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import { LEGACY_OPTIONS } from 'wgpathd.config';
import { is_pubkey } from 'wgpathd.wg';

function legacy_sections(uci) {
	let out = [];
	uci.foreach('network', null, (s) => {
		let wireguard = index(s['.type'], 'wireguard_') == 0;
		if (wireguard && length(filter(values(LEGACY_OPTIONS), (opt) => s[opt] != null)) > 0)
			push(out, s);
	});
	return out;
}

// The first `peer` section of each public key.
function peer_sections(uci) {
	let out = {};
	uci.foreach('wgpathd', 'peer', (s) => {
		if (type(s.public_key) == 'string')
			out[s.public_key] ??= s['.name'];
	});
	return out;
}

function failed(uci, what) {
	return Result.err(errors.MIGRATE_FAILED, `${what}: ${uci.error() ?? 'unknown error'}`);
}

// Adds or completes the peer section of network section s.
function move(uci, sections, s, log) {
	let name = sections[s.public_key];
	if (name == null) {
		name = uci.add('wgpathd', 'peer');
		if (name == null || !uci.set('wgpathd', name, 'public_key', s.public_key))
			return failed(uci, 'cannot add a peer to /etc/config/wgpathd');
		sections[s.public_key] = name;
	}
	for (let opt, legacy in LEGACY_OPTIONS) {
		let value = s[legacy];
		if (value == null)
			continue;
		let kept = uci.get('wgpathd', name, opt);
		if (kept == null && !uci.set('wgpathd', name, opt, value))
			return failed(uci, `cannot set ${opt} in /etc/config/wgpathd`);
		if (kept != null && kept != value)
			log('warning', `migrate: network section ${s['.name']}: kept ${opt} '${kept}' of /etc/config/wgpathd, dropped ${legacy} '${value}'`);
	}
	return Result.ok();
}

function remove_legacy(uci, moved) {
	for (let s in moved)
		for (let legacy in values(LEGACY_OPTIONS))
			if (s[legacy] != null && !uci.delete('network', s['.name'], legacy))
				return failed(uci, `cannot remove ${legacy} from network section ${s['.name']}`);
	return uci.commit('network') ? Result.ok() : failed(uci, 'cannot write /etc/config/network');
}

// Returns the number of network sections moved. A section without a valid public key
// cannot be keyed, so its options stay where they are.
export function run(uci, log) {
	let moved = [];
	for (let s in legacy_sections(uci))
		if (is_pubkey(s.public_key))
			push(moved, s);
		else
			log('warning', `migrate: network section ${s['.name']} has no valid public_key, its options stay`);
	if (length(moved) == 0)
		return Result.ok(0);

	let sections = peer_sections(uci);
	for (let s in moved) {
		let res = move(uci, sections, s, log);
		if (!res.ok)
			return res;
	}
	if (!uci.commit('wgpathd'))
		return failed(uci, 'cannot write /etc/config/wgpathd');
	let removed = remove_legacy(uci, moved);
	if (!removed.ok)
		return removed;
	log('notice', `migrate: moved the settings of ${length(moved)} peer(s) from /etc/config/network to /etc/config/wgpathd`);
	return Result.ok(length(moved));
};
