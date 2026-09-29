'use strict';

// Load /etc/config/wgpathd via deps.uci. On a spoke, its `peer` sections give each
// steered peer a relay and a tunnel address, matched by public key to the WireGuard
// peers of mesh_iface in /etc/config/network.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import * as endpoint from 'wgpathd.endpoint';
import * as address from 'wgpathd.address';
import { parse_url } from 'wgpathd.discovery';
import { is_pubkey } from 'wgpathd.wg';
import * as parameters from 'wgpathd.params';

const REQUIRED = {
	spoke: [ 'mesh_iface', 'hub_iface', 'discovery' ],
	hub:   [ 'read_iface', 'serve_addr', 'serve_port' ],
};

const INTERFACES = {
	spoke: [ 'mesh_iface', 'hub_iface' ],
	hub:   [ 'read_iface' ],
};

const INTERFACE_NAME = 'must be an interface name of letters, digits and _';

function invalid(option, reason) {
	return Result.err(errors.CONFIG_INVALID_OPTION, `${option} ${reason}`);
}

// UCI reads a name like `@interface[0]` as a lookup by position, so only a plain
// name may reach a cursor.
export function is_name(s) {
	return type(s) == 'string' && match(s, /^[A-Za-z0-9_]+$/) != null;
};

function missing_option(main, role) {
	for (let opt in REQUIRED[role])
		if (type(main[opt]) != 'string' || main[opt] == '')
			return opt;
	return null;
}

// Decimal digits only: `socket.listen` would read `0x50` as 80 and ` 22 ` as 22.
function is_port(s) {
	return match(s, /^[1-9][0-9]{0,4}$/) != null && +s <= 65535;
}

// uclient reads the scheme case-sensitively, and https would need a TLS context the
// daemon does not set up.
function is_discovery_url(s) {
	let u = parse_url(s);
	return u != null && u.scheme == 'http' && (u.port == null || is_port(u.port));
}

// What a required option must look like, before anything reads it: [ test, what it must be ].
const FORMATS = {
	mesh_iface: [ is_name, INTERFACE_NAME ],
	hub_iface:  [ is_name, INTERFACE_NAME ],
	read_iface: [ is_name, INTERFACE_NAME ],
	discovery:  [ is_discovery_url, 'must be a URL of the form http://<host>[:<port>]/<path>' ],
	serve_addr: [ address.can_listen, 'must be an IP address of the router, not unspecified or multicast' ],
	serve_port: [ is_port, 'must be a port number from 1 to 65535' ],
};

function malformed_option(main, role) {
	for (let opt in REQUIRED[role])
		if (FORMATS[opt] != null && !FORMATS[opt][0](main[opt]))
			return invalid(opt, FORMATS[opt][1]);
	return null;
}

function missing_interface(uci, main, role) {
	for (let opt in INTERFACES[role])
		if (uci.get('network', main[opt]) != 'interface')
			return main[opt];
	return null;
}

// Only a spoke uses the parameters that could conflict.
function parse_overrides(main, role) {
	let overrides = {};
	for (let name in keys(parameters.DEFAULTS)) {
		if (main[name] == null)
			continue;
		let value = parameters.parse(name, main[name]);
		if (value == null)
			return invalid(name, parameters.bounds_text(name));
		overrides[name] = value;
	}
	let conflict = (role == 'spoke') ? parameters.conflict({ ...parameters.DEFAULTS, ...overrides }) : null;
	return conflict ? invalid(conflict[0], conflict[1]) : Result.ok(overrides);
}

// Where releases up to 4 kept a peer's settings: options of its network section.
export const LEGACY_OPTIONS = { relay: 'wgpathd_relay', tunnel: 'wgpathd_tunnel' };

// The `peer` sections by public key; a section without one is counted apart.
function peer_settings(uci) {
	let settings = { by_key: {}, unkeyed: 0 };
	uci.foreach('wgpathd', 'peer', (s) => {
		if (type(s.public_key) != 'string')
			return settings.unkeyed++;
		settings.by_key[s.public_key] ??= [];
		push(settings.by_key[s.public_key], s);
	});
	return settings;
}

function unmanaged_reason(s, settings) {
	if (!is_pubkey(s.public_key))
		return 'invalid public_key';
	let found = settings.by_key[s.public_key] ?? [];
	if (length(found) == 0)
		return 'not configured';
	if (length(found) > 1)
		return 'configured more than once';
	let p = found[0];
	if (p.relay == null)
		return 'missing relay';
	if (endpoint.canonical(p.relay) == null)
		return 'invalid relay';
	if (p.tunnel == null)
		return 'missing tunnel';
	if (endpoint.canonical_ip(p.tunnel) == null)
		return 'invalid tunnel';
	return null;
}

// One bad peer is left alone and reported, never a reason to refuse the whole config.
// Settings whose key is no peer of mesh_iface are stale: listed apart, and ignored.
function load_peers(uci, mesh_iface) {
	let settings = peer_settings(uci);
	let peers = { managed: [], unmanaged: [], stale: [] };
	let mesh_keys = {};
	uci.foreach('network', `wireguard_${mesh_iface}`, (s) => {
		mesh_keys[s.public_key] = true;
		let reason = unmanaged_reason(s, settings);
		if (reason != null)
			return push(peers.unmanaged, { section: s['.name'], pubkey: s.public_key, reason: reason });
		let p = settings.by_key[s.public_key][0];
		push(peers.managed, { section: s['.name'], pubkey: s.public_key,
			relay: endpoint.canonical(p.relay), tunnel: endpoint.canonical_ip(p.tunnel) });
	});
	for (let key in keys(settings.by_key))
		if (!mesh_keys[key])
			push(peers.stale, { pubkey: key });
	for (let i = 0; i < settings.unkeyed; i++)
		push(peers.stale, { pubkey: null });
	return peers;
}

// Network sections that still carry the options of releases up to 4, which nothing reads.
function leftovers(uci) {
	let out = [];
	uci.foreach('network', null, (s) => {
		let options = filter(values(LEGACY_OPTIONS), (opt) => s[opt] != null);
		if (length(options) > 0)
			push(out, { section: s['.name'], options: options });
	});
	return out;
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

	let malformed = malformed_option(main, role);
	if (malformed != null)
		return malformed;

	let iface = missing_interface(deps.uci, main, role);
	if (iface != null)
		return Result.err(errors.INTERFACE_MISSING, iface);

	let overrides = parse_overrides(main, role);
	if (!overrides.ok)
		return overrides;

	let cfg = { role: role, ...pick(main, REQUIRED[role]), overrides: overrides.data, leftovers: leftovers(deps.uci) };
	if (role == 'hub')
		return Result.ok({ ...cfg, serve_addr: endpoint.canonical_ip(main.serve_addr) });

	cfg.mode = (main.mode == 'steer') ? 'steer' : 'observe';
	if (main.mode != null && !(main.mode in [ 'steer', 'observe' ]))
		cfg.invalid_mode = main.mode;
	cfg.peers = load_peers(deps.uci, main.mesh_iface);
	return Result.ok(cfg);
};
