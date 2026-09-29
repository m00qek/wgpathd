'use strict';

// `service wgpathd check` and the `wgpathd.config` check: validate the config with the
// daemon's own loader and, unless config_only, the substrate it needs (interfaces,
// peer annotations, relay routes). findings() is pure; run() gathers what it reads.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import * as config from 'wgpathd.config';
import * as relay from 'wgpathd.relay';
import * as wg from 'wgpathd.wg';
import * as endpoint from 'wgpathd.endpoint';
import { parse_url } from 'wgpathd.discovery';

const LABELS = { ok: 'ok  ', skip: 'skip', warn: 'warn', fail: 'FAIL' };
const DISABLED = [ '0', 'no', 'off', 'false', 'disabled' ];

function explain(res) {
	switch (res.error) {
	case errors.CONFIG_INVALID_ROLE:
		return `option role must be 'spoke' or 'hub' (is ${res.details})`;
	case errors.CONFIG_MISSING_OPTION:
		return `missing option ${res.details}`;
	case errors.CONFIG_INVALID_OPTION:
		return `option ${res.details}`;
	case errors.INTERFACE_MISSING:
		return `no interface ${res.details} in /etc/config/network`;
	}
	return Result.describe(res);
}

// The option a loader error is about, when it names one. An invalid option's
// detail is its name, then what it must be.
function failed_option(res) {
	switch (res.error) {
	case errors.CONFIG_INVALID_ROLE:
		return 'role';
	case errors.CONFIG_MISSING_OPTION:
		return res.details;
	case errors.CONFIG_INVALID_OPTION:
		return split(res.details, ' ')[0];
	}
	return null;
}

function count(n, noun) {
	return `${n} ${noun}${n == 1 ? '' : 's'}`;
}

function summary(cfg) {
	if (cfg.role == 'hub')
		return `hub, reads ${cfg.read_iface}, serves ${cfg.serve_addr}:${cfg.serve_port}`;
	return `spoke, mode ${cfg.mode}, ${count(length(cfg.peers.managed), 'steered peer')}, ` +
		`${length(cfg.peers.unmanaged)} not steered`;
}

// Null on a hub.
function discovery_host(cfg) {
	let host = (cfg.role == 'spoke') ? parse_url(cfg.discovery)?.host : null;
	return (host != null) ? { name: host, address: endpoint.canonical_ip(host) } : null;
}

// uclient resolves a name with a blocking lookup, which holds up the daemon's loop.
function check_config(cfg, add) {
	add('ok', 'config', `config: ${summary(cfg)}`);
	if (cfg.invalid_mode != null)
		add('warn', 'config', `config: unknown mode '${cfg.invalid_mode}' runs as observe`, { option: 'mode' });
	let host = discovery_host(cfg);
	if (host != null && host.address == null)
		add('warn', 'config', `config: discovery host ${host.name} is a name, not an address: every fetch waits for DNS`,
			{ option: 'discovery' });
}

// Discovery must keep working while the mesh is down, so it goes through the hub tunnel.
function check_discovery_route(cfg, route, add) {
	if (route == null)
		return;
	let host = discovery_host(cfg).address;
	if (!route.ok)
		add('warn', 'config', `config: discovery host ${host}: route lookup failed: ${Result.describe(route)}`, { option: 'discovery' });
	else if (route.data.oif != cfg.hub_iface)
		add('warn', 'config', `config: discovery host ${host} routes via ${route.data.oif}, not ${cfg.hub_iface}`, { option: 'discovery' });
}

function check_enabled(enabled, add) {
	if (enabled != null && enabled in DISABLED)
		add('warn', 'config', `service disabled (option enabled '${enabled}'): it will not start`, { option: 'enabled' });
}

// Only the firewall keeps the discovery server off other networks, and the shipped rule
// accepts its port only from WireGuard interfaces: an address elsewhere is worth a word.
function check_listener(cfg, wireguard_addresses, add) {
	if (wireguard_addresses != null && !(cfg.serve_addr in wireguard_addresses))
		add('warn', 'config', `config: serve_addr ${cfg.serve_addr} is no address of a WireGuard interface in /etc/config/network`,
			{ option: 'serve_addr' });
}

// Returns the interface's kernel peers, or null when it is missing or unreadable.
function check_interface(status, iface, required, add) {
	let peers = status.ok ? wg.parse_status(status.data, iface) : status;
	if (!peers.ok) {
		let why = (peers.error == errors.WG_PARSE_FAILED) ? peers.details : Result.describe(peers);
		add(required ? 'fail' : 'warn', iface, `${iface}: ${why}`);
		return null;
	}
	add('ok', iface, `${iface}: up, ${count(length(peers.data), 'peer')}`);
	return peers.data;
}

function check_managed(cfg, peer, verdict, kernel, add) {
	let name = `peer ${peer.section}`;
	let about = { section: peer.section };
	if (verdict.verdict == relay.REJECTED)
		return add('fail', 'peer', `${name}: ${verdict.reason}`, { ...about, option: 'wgpathd_relay' });
	if (verdict.verdict == relay.PENDING)
		return add('warn', 'peer', `${name}: ${verdict.reason} (retried every cycle)`, about);
	add('ok', 'peer', `${name}: relay ${peer.relay} via ${verdict.oif}, probes ${peer.tunnel}`, about);
	if (kernel != null && kernel[peer.pubkey] == null)
		add('warn', 'peer', `${name}: not in ${cfg.mesh_iface} yet, skipped until it appears`, about);
}

// A peer without annotations is simply not steered; a malformed annotation is a mistake.
function check_unmanaged(u, add) {
	let words = split(u.reason, ' ');
	let level = (words[0] == 'missing') ? 'skip' : 'fail';
	add(level, 'peer', `peer ${u.section}: not steered (${u.reason})`, { section: u.section, option: words[1] });
}

// Interfaces are checked only when `wireguard status` was read, and skipped when ubus
// was unreachable: the check then runs outside a live system.
function check_substrate(cfg, obs, add) {
	let status = obs.wireguard;
	let skipped = status != null && !status.ok && status.error == errors.UBUS_CONNECT_FAILED;
	if (skipped)
		add('skip', 'ubus', 'ubus unavailable: interfaces not checked');
	let iface = (name, required) => (status == null || skipped) ? null : check_interface(status, name, required, add);

	if (cfg.role == 'hub') {
		check_listener(cfg, obs.wireguard_addresses, add);
		return iface(cfg.read_iface, true);
	}
	check_discovery_route(cfg, obs.discovery_route, add);
	let kernel = iface(cfg.mesh_iface, true);
	iface(cfg.hub_iface, false);
	for (let peer in cfg.peers.managed)
		check_managed(cfg, peer, obs.routes[peer.section], kernel, add);
	for (let u in cfg.peers.unmanaged)
		check_unmanaged(u, add);
}

// loaded: config.load's result. obs: what the system looked like, or null for the
// config alone: { enabled, wireguard: the `wireguard status` Result or null when not
// read, routes: { <section>: relay.guard verdict }, discovery_route: on a spoke, the
// route_get Result for the discovery host, null when it is a name; wireguard_addresses:
// on a hub, the addresses /etc/config/network gives its WireGuard interfaces }.
export function findings(loaded, obs) {
	let list = [];
	let add = (level, subject, message, about) => push(list, { level: level, subject: subject, ...(about ?? {}), message: message });

	if (!loaded.ok) {
		let option = failed_option(loaded);
		add('fail', 'config', `config: ${explain(loaded)}`, option ? { option: option } : null);
		return list;
	}
	check_config(loaded.data, add);
	if (obs != null) {
		check_enabled(obs.enabled, add);
		check_substrate(loaded.data, obs, add);
	}
	return list;
};

export function passed(list) {
	return length(filter(list, (f) => f.level == 'fail')) == 0;
};

export function render(list) {
	return join('', map(list, (f) => `${LABELS[f.level]}  ${f.message}\n`));
};

function wireguard_addresses(uci) {
	let out = [];
	uci.foreach('network', 'interface', (s) => {
		if (s.proto != 'wireguard')
			return;
		let list = (type(s.addresses) == 'array') ? s.addresses : split(s.addresses ?? '', /\s+/);
		for (let a in list)
			push(out, endpoint.canonical_ip(split(a, '/')[0]));
	});
	return out;
}

// Without deps.ubus the interfaces are not read: rpcd serves `wireguard status`
// itself, so a plugin running inside it cannot wait for that answer.
function observe(deps, cfg) {
	let spoke = cfg.role == 'spoke';
	let routes = {};
	if (spoke)
		for (let peer in cfg.peers.managed)
			routes[peer.section] = relay.guard(deps.route_get, cfg.mesh_iface, peer);
	let host = discovery_host(cfg)?.address;
	return {
		enabled: deps.uci.get('wgpathd', 'main', 'enabled'),
		wireguard: deps.ubus?.call('wireguard', 'status', {}),
		routes: routes,
		discovery_route: (host != null) ? deps.route_get(host) : null,
		wireguard_addresses: spoke ? null : wireguard_addresses(deps.uci),
	};
}

export function run(deps, opts) {
	let loaded = config.load(deps);
	let obs = (loaded.ok && !opts?.config_only) ? observe(deps, loaded.data) : null;
	let list = findings(loaded, obs);
	return { ok: passed(list), findings: list, report: render(list) };
};
