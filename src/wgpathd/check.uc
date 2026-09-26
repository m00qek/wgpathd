'use strict';

// `service wgpathd check`: validate the config with the daemon's own loader and, unless
// config_only, the substrate it needs (interfaces, peer annotations, relay routes).

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

function summary(cfg) {
	if (cfg.role == 'hub')
		return `hub, reads ${cfg.read_iface}, serves ${cfg.serve_addr}:${cfg.serve_port}`;
	return `spoke, mode ${cfg.mode}, ${length(cfg.peers.managed)} steered peers, ` +
		`${length(cfg.peers.unmanaged)} not steered`;
}

function check_config(cfg, add) {
	add('ok', `config: ${summary(cfg)}`);
	if (cfg.invalid_mode != null)
		add('warn', `config: unknown mode '${cfg.invalid_mode}' runs as observe`);
}

function check_enabled(uci, add) {
	let enabled = uci.get('wgpathd', 'main', 'enabled');
	if (enabled != null && enabled in DISABLED)
		add('warn', `service disabled (option enabled '${enabled}'): it will not start`);
}

// Returns the interface's kernel peers, or null when it is missing or unreadable.
function check_interface(status, iface, required, add) {
	let peers = status.ok ? wg.parse_status(status.data, iface) : status;
	if (!peers.ok) {
		let why = (peers.error == errors.WG_PARSE_FAILED) ? peers.details : Result.describe(peers);
		add(required ? 'fail' : 'warn', `${iface}: ${why}`);
		return null;
	}
	add('ok', `${iface}: up, ${length(peers.data)} peers`);
	return peers.data;
}

function check_managed(deps, cfg, peer, kernel, add) {
	let name = `peer ${peer.section}`;
	let v = relay.guard(deps.route_get, cfg.mesh_iface, peer);
	if (v.verdict == relay.REJECTED)
		return add('fail', `${name}: ${v.reason}`);
	if (v.verdict == relay.PENDING)
		return add('warn', `${name}: ${v.reason} (retried every cycle)`);
	add('ok', `${name}: relay ${peer.relay} via ${v.oif}, probes ${peer.tunnel}`);
	if (kernel != null && kernel[peer.pubkey] == null)
		add('warn', `${name}: not in ${cfg.mesh_iface} yet, skipped until it appears`);
}

// A peer without annotations is simply not steered; a malformed annotation is a mistake.
function check_unmanaged(u, add) {
	let level = (index(u.reason, 'missing ') == 0) ? 'skip' : 'fail';
	add(level, `peer ${u.section}: not steered (${u.reason})`);
}

// Only an unreachable ubus skips the interfaces: the check then runs outside a live system.
function check_substrate(deps, cfg, add) {
	let status = deps.ubus.call('wireguard', 'status', {});
	let skipped = !status.ok && status.error == errors.UBUS_CONNECT_FAILED;
	if (skipped)
		add('skip', 'ubus unavailable: interfaces not checked');
	let iface = (name, required) => skipped ? null : check_interface(status, name, required, add);

	if (cfg.role == 'hub')
		return iface(cfg.read_iface, true);
	let kernel = iface(cfg.mesh_iface, true);
	iface(cfg.hub_iface, false);
	for (let peer in cfg.peers.managed)
		check_managed(deps, cfg, peer, kernel, add);
	for (let u in cfg.peers.unmanaged)
		check_unmanaged(u, add);
}

function render(findings) {
	return join('', map(findings, (f) => `${LABELS[f.level]}  ${f.text}\n`));
}

export function run(deps, opts) {
	let findings = [];
	let add = (level, text) => push(findings, { level: level, text: text });

	let loaded = config.load(deps);
	if (!loaded.ok)
		add('fail', `config: ${explain(loaded)}`);
	else {
		check_config(loaded.data, add);
		if (!opts?.config_only) {
			check_enabled(deps.uci, add);
			check_substrate(deps, loaded.data, add);
		}
	}
	let ok = length(filter(findings, (f) => f.level == 'fail')) == 0;
	return { ok: ok, findings: findings, report: render(findings) };
};
