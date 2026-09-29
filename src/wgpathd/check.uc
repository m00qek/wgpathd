'use strict';

// `service wgpathd check` and the `wgpathd.config` check: validate the config with the
// daemon's own loader and, unless config_only, the substrate it needs (interfaces,
// peer annotations, relay routes). findings() is pure; run() gathers what it reads.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import * as config from 'wgpathd.config';
import * as relay from 'wgpathd.relay';
import * as wg from 'wgpathd.wg';

const LABELS = { ok: 'ok  ', skip: 'skip', warn: 'warn', fail: 'FAIL' };
const DISABLED = [ '0', 'no', 'off', 'false', 'disabled' ];

function explain(res) {
	switch (res.error) {
	case errors.CONFIG_INVALID_ROLE:
		return `option role must be 'spoke' or 'hub' (is ${res.details})`;
	case errors.CONFIG_MISSING_OPTION:
		return `missing option ${res.details}`;
	case errors.CONFIG_INVALID_OPTION:
		return `option ${res.details} must be a positive number`;
	case errors.INTERFACE_MISSING:
		return `no interface ${res.details} in /etc/config/network`;
	}
	return Result.describe(res);
}

// The option a loader error is about, when it names one.
function failed_option(res) {
	switch (res.error) {
	case errors.CONFIG_INVALID_ROLE:
		return 'role';
	case errors.CONFIG_MISSING_OPTION:
	case errors.CONFIG_INVALID_OPTION:
		return res.details;
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

function check_config(cfg, add) {
	add('ok', 'config', `config: ${summary(cfg)}`);
	if (cfg.invalid_mode != null)
		add('warn', 'config', `config: unknown mode '${cfg.invalid_mode}' runs as observe`, { option: 'mode' });
}

function check_enabled(enabled, add) {
	if (enabled != null && enabled in DISABLED)
		add('warn', 'config', `service disabled (option enabled '${enabled}'): it will not start`, { option: 'enabled' });
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

	if (cfg.role == 'hub')
		return iface(cfg.read_iface, true);
	let kernel = iface(cfg.mesh_iface, true);
	iface(cfg.hub_iface, false);
	for (let peer in cfg.peers.managed)
		check_managed(cfg, peer, obs.routes[peer.section], kernel, add);
	for (let u in cfg.peers.unmanaged)
		check_unmanaged(u, add);
}

// loaded: config.load's result. obs: what the system looked like, or null for the
// config alone: { enabled, wireguard: the `wireguard status` Result or null when not
// read, routes: { <section>: relay.guard verdict } }.
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

// Without deps.ubus the interfaces are not read: rpcd serves `wireguard status`
// itself, so a plugin running inside it cannot wait for that answer.
function observe(deps, cfg) {
	let routes = {};
	if (cfg.role == 'spoke')
		for (let peer in cfg.peers.managed)
			routes[peer.section] = relay.guard(deps.route_get, cfg.mesh_iface, peer);
	return {
		enabled: deps.uci.get('wgpathd', 'main', 'enabled'),
		wireguard: deps.ubus?.call('wireguard', 'status', {}),
		routes: routes,
	};
}

export function run(deps, opts) {
	let loaded = config.load(deps);
	let obs = (loaded.ok && !opts?.config_only) ? observe(deps, loaded.data) : null;
	let list = findings(loaded, obs);
	return { ok: passed(list), findings: list, report: render(list) };
};
