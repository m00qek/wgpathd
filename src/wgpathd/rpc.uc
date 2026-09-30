'use strict';

// The `wgpathd.config` ubus object, which rpcd serves through
// /usr/share/rpcd/ucode/wgpathd.uc whether or not the daemon runs.
//
//   check {}                          -> { ok, findings: [ { level, subject, section?, public_key?, option?, message, fix? } ] }
//   check { candidate: { main, peers } } the same, for unsaved values over the committed config
//   peers { iface? }                  -> { iface, interfaces: [ <name> ], peers: [ { section, public_key, description?, fixed_endpoint? } ] }
//   schema {}                         -> { parameters: [ { name, default, min, max, whole } ] }
//
// A malformed candidate is answered { error: "CHECK_INVALID_CANDIDATE", message }, an
// iface that is no WireGuard interface { error: "PEERS_INVALID_IFACE", message }.

import * as errors from 'wgpathd.errors';
import * as check from 'wgpathd.check';
import * as parameters from 'wgpathd.params';
import { overlay } from 'wgpathd.candidate';
import { is_name, has_fixed_endpoint } from 'wgpathd.config';

// The interface whose peers a role steers or publishes.
const ROLE_IFACE = { spoke: 'mesh_iface', hub: 'read_iface' };

// A fresh cursor per call: rpcd outlives any number of commits.
export function run_check(deps, candidate) {
	let uci = deps.uci_cursor();
	if (candidate != null) {
		let view = overlay(uci, candidate);
		if (!view.ok)
			return { error: view.error, message: view.details };
		uci = view.data;
	}
	let res = check.run({ uci: uci, fs: deps.fs, route_get: deps.route_get });
	return { ok: res.ok, findings: res.findings };
};

function wireguard_interfaces(uci) {
	let names = [];
	uci.foreach('network', 'interface', (s) => {
		if (s.proto == 'wireguard' && is_name(s['.name']))
			push(names, s['.name']);
	});
	return sort(names);
}

// Only these options of a peer section leave the router: /etc/config/network also holds
// every private and preshared key. Whether the peer has a fixed endpoint is told, not
// the endpoint.
function peer_entry(s) {
	let entry = { section: s['.name'], public_key: (type(s.public_key) == 'string') ? s.public_key : null };
	if (type(s.description) == 'string')
		entry.description = s.description;
	if (has_fixed_endpoint(s))
		entry.fixed_endpoint = true;
	return entry;
}

// Without iface, the interface of the committed role, if it is a WireGuard interface.
export function list_peers(deps, iface) {
	let uci = deps.uci_cursor();
	let interfaces = wireguard_interfaces(uci);
	if (iface == null) {
		let main = uci.get_all('wgpathd', 'main') ?? {};
		iface = main[ROLE_IFACE[main.role]];
		if (!(iface in interfaces))
			iface = null;
	}
	else if (!is_name(iface) || !(iface in interfaces))
		return { error: errors.PEERS_INVALID_IFACE, message: 'iface must name a WireGuard interface of /etc/config/network' };

	let peers = [];
	if (iface != null)
		uci.foreach('network', `wireguard_${iface}`, (s) => push(peers, peer_entry(s)));
	return { iface: iface, interfaces: interfaces, peers: peers };
};

export function schema() {
	return { parameters: map(keys(parameters.DEFAULTS), (name) => ({ name: name, default: parameters.DEFAULTS[name],
		min: parameters.BOUNDS[name].min, max: parameters.BOUNDS[name].max, whole: parameters.BOUNDS[name].whole == true })) };
};

export function methods(deps) {
	return {
		check: {
			args: { candidate: {} },
			call: (req) => run_check(deps, req.args?.candidate),
		},
		peers: {
			args: { iface: '' },
			call: (req) => list_peers(deps, req.args?.iface),
		},
		schema: {
			args: {},
			call: () => schema(),
		},
	};
};
