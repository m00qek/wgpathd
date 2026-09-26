'use strict';

// Load /etc/config/wgpathd and the steered wg peers from /etc/config/network via deps.uci.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import * as endpoint from 'wgpathd.endpoint';
import { is_pubkey } from 'wgpathd.wg';
import { DEFAULTS } from 'wgpathd.params';

const REQUIRED = {
	spoke: [ 'mesh_iface', 'hub_iface', 'discovery' ],
	hub:   [ 'read_iface', 'serve_addr', 'serve_port' ],
};

const INTERFACES = {
	spoke: [ 'mesh_iface', 'hub_iface' ],
	hub:   [ 'read_iface' ],
};

function missing_option(main, role) {
	for (let opt in REQUIRED[role])
		if (type(main[opt]) != 'string' || main[opt] == '')
			return opt;
	return null;
}

function missing_interface(uci, main, role) {
	for (let opt in INTERFACES[role])
		if (uci.get('network', main[opt]) != 'interface')
			return main[opt];
	return null;
}

function positive_number(v) {
	return type(v) == 'string' && match(v, /^[0-9]+(\.[0-9]+)?$/) != null && +v > 0;
}

function parse_overrides(main) {
	let overrides = {};
	for (let name in keys(DEFAULTS)) {
		if (main[name] == null)
			continue;
		if (!positive_number(main[name]))
			return Result.err(errors.CONFIG_INVALID_OPTION, name);
		overrides[name] = +main[name];
	}
	return Result.ok(overrides);
}

function unmanaged_reason(s) {
	if (!is_pubkey(s.public_key))
		return 'invalid public_key';
	if (s.wgpathd_relay == null)
		return 'missing wgpathd_relay';
	if (endpoint.canonical(s.wgpathd_relay) == null)
		return 'invalid wgpathd_relay';
	if (s.wgpathd_tunnel == null)
		return 'missing wgpathd_tunnel';
	if (endpoint.canonical_ip(s.wgpathd_tunnel) == null)
		return 'invalid wgpathd_tunnel';
	return null;
}

// One bad peer is left alone and reported, never a reason to refuse the whole config.
function load_peers(uci, mesh_iface) {
	let peers = { managed: [], unmanaged: [] };
	uci.foreach('network', `wireguard_${mesh_iface}`, (s) => {
		let reason = unmanaged_reason(s);
		if (reason != null)
			push(peers.unmanaged, { section: s['.name'], pubkey: s.public_key, reason: reason });
		else
			push(peers.managed, { section: s['.name'], pubkey: s.public_key,
				relay: endpoint.canonical(s.wgpathd_relay), tunnel: endpoint.canonical_ip(s.wgpathd_tunnel) });
	});
	return peers;
}

function pick(main, opts) {
	let out = {};
	for (let opt in opts)
		out[opt] = main[opt];
	return out;
}

export function load(deps) {
	let main = deps.uci.get_all('wgpathd', 'main') ?? {};
	let role = main.role;
	if (REQUIRED[role] == null)
		return Result.err(errors.CONFIG_INVALID_ROLE, role ?? 'unset');

	let opt = missing_option(main, role);
	if (opt != null)
		return Result.err(errors.CONFIG_MISSING_OPTION, opt);

	let iface = missing_interface(deps.uci, main, role);
	if (iface != null)
		return Result.err(errors.INTERFACE_MISSING, iface);

	let overrides = parse_overrides(main);
	if (!overrides.ok)
		return overrides;

	let cfg = { role: role, ...pick(main, REQUIRED[role]), overrides: overrides.data };
	if (role == 'spoke') {
		cfg.mode = (main.mode == 'steer') ? 'steer' : 'observe';
		if (main.mode != null && !(main.mode in [ 'steer', 'observe' ]))
			cfg.invalid_mode = main.mode;
		cfg.peers = load_peers(deps.uci, main.mesh_iface);
	}
	return Result.ok(cfg);
};
