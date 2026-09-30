'use strict';

// `service wgpathd check` and the `wgpathd.config` check: validate the config with the
// daemon's own loader and, unless config_only, the substrate it needs (interfaces,
// peer settings, relay routes, firewall rules). findings() is pure; run() gathers what
// it reads.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import * as config from 'wgpathd.config';
import * as relay from 'wgpathd.relay';
import * as wg from 'wgpathd.wg';
import * as endpoint from 'wgpathd.endpoint';
import * as firewall from 'wgpathd.firewall';
import { parse_url } from 'wgpathd.discovery';

const LABELS = { ok: 'ok  ', skip: 'skip', warn: 'warn', fail: 'FAIL' };
const DISABLED = [ '0', 'no', 'off', 'false', 'disabled' ];

// Each reason a mesh peer is not steered, and the option it is about. A peer without
// settings, with a fixed endpoint or not, is simply not steered; settings half given
// or malformed are a mistake.
const UNMANAGED = {
	'invalid public_key':        { level: 'fail', option: 'public_key' },
	'not configured':            { level: 'skip' },
	'fixed endpoint':            { level: 'skip' },
	'configured more than once': { level: 'fail' },
	'missing relay':             { level: 'fail', option: 'relay' },
	'invalid relay':             { level: 'fail', option: 'relay' },
	'missing tunnel':            { level: 'fail', option: 'tunnel' },
	'invalid tunnel':            { level: 'fail', option: 'tunnel' },
};

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

function check_leftovers(cfg, add) {
	for (let l in cfg.leftovers)
		add('warn', 'config', `config: network section ${l.section}: ${join(' and ', l.options)} left over from an earlier ` +
			`version, ignored; run service wgpathd migrate or remove ${length(l.options) == 1 ? 'it' : 'them'}`,
			{ section: l.section });
}

function check_stale(cfg, add) {
	for (let s in cfg.peers.stale)
		if (s.pubkey == null)
			add('warn', 'peer', 'peer settings without a public_key: ignored');
		else
			add('warn', 'peer', `peer settings for ${s.pubkey}: no such peer in ${cfg.mesh_iface}, ignored`,
				{ public_key: s.pubkey });
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
	check_leftovers(cfg, add);
	if (cfg.role == 'spoke')
		check_stale(cfg, add);
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

// Only the firewall keeps the discovery server off other networks, and it is meant to
// accept the port from the hub tunnel alone: an address elsewhere is worth a word.
function check_listener(cfg, interfaces, add) {
	let held = (addr) => length(filter(values(interfaces), (i) => addr in i.addresses)) > 0;
	if (interfaces != null && !held(cfg.serve_addr))
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

// A peer finding names the network section and, when it is one, the public key.
function peer_about(peer) {
	return wg.is_pubkey(peer.pubkey) ? { section: peer.section, public_key: peer.pubkey } : { section: peer.section };
}

function check_managed(cfg, peer, verdict, kernel, add) {
	let name = `peer ${peer.section}`;
	let about = peer_about(peer);
	if (verdict.verdict == relay.REJECTED)
		return add('fail', 'peer', `${name}: ${verdict.reason}`, { ...about, option: 'relay' });
	if (verdict.verdict == relay.PENDING)
		return add('warn', 'peer', `${name}: ${verdict.reason} (retried every cycle)`, about);
	add('ok', 'peer', `${name}: relay ${peer.relay} via ${verdict.oif}, probes ${peer.tunnel}`, about);
	if (kernel != null && kernel[peer.pubkey] == null)
		add('warn', 'peer', `${name}: not in ${cfg.mesh_iface} yet, skipped until it appears`, about);
}

function check_unmanaged(u, add) {
	let why = UNMANAGED[u.reason];
	let about = peer_about(u);
	if (why.option != null)
		about.option = why.option;
	add(why.level, 'peer', `peer ${u.section}: not steered (${u.reason})`, about);
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
		check_listener(cfg, obs.interfaces, add);
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

const FLOWS = {
	tunnel:    (f) => `${(f.family == 6) ? 'ICMPv6' : 'ICMP'} echo-request (tunnel probe)`,
	underlay:  () => 'ICMPv6 echo-request (underlay probe)',
	relay:     (f) => (f.port != null) ? `UDP port ${f.port} (relayed WireGuard)` : 'UDP (relayed WireGuard)',
	discovery: (f) => `TCP port ${f.port} (peer list)`,
};

const UNSURE_BECAUSE = {
	[firewall.CONDITIONS]:  () => 'a rule or zone option this check does not follow applies',
	[firewall.CUSTOM]:      () => 'the firewall has custom nftables rules',
	[firewall.MATCHED_BY]:  () => 'a zone may take it by device or subnet',
	[firewall.ZONE_FAMILY]: (cfg, flow, v) => `zone ${v.zone} is not for IPv${flow.family}`,
	[firewall.NO_PORT]:     (cfg) => `${cfg.mesh_iface} has no listen_port`,
	[firewall.NOT_FOUND]:   () => 'no such zone',
};

function flow_source(flow, zone) {
	if (flow.zone != null)
		return `zone ${flow.zone}`;
	return `${flow.iface} (${(zone != null) ? `zone ${zone}` : 'no zone'})`;
}

function flow_outcome(cfg, flow, v) {
	if (v.verdict == firewall.ACCEPTED)
		return 'accepted';
	if (v.verdict == firewall.UNSURE)
		return `could not confirm, ${UNSURE_BECAUSE[v.reason](cfg, flow, v)}`;
	if (v.reason == firewall.REJECTED)
		return 'a rule rejects it before any accepts it';
	if (v.reason == firewall.NO_ZONE)
		return `no rule accepts it; put ${flow.iface} in a firewall zone`;
	return (flow.kind == 'underlay') ? "no rule accepts it: restore OpenWrt's default rule Allow-ICMPv6-Input" : 'no rule accepts it';
}

// The package opens nothing, so each flow wgpathd needs is looked for in the rules the
// operator added; a firewall this cannot read in full is only ever a warning.
function check_firewall(cfg, obs, add) {
	if (obs.firewall == null)
		return;
	if (!obs.firewall.found)
		return add('skip', 'firewall', 'firewall: no /etc/config/firewall, not checked');
	let flows = firewall.needs(cfg, obs.interfaces ?? {});
	for (let flow in flows) {
		let v = firewall.verdict(obs.firewall, flow);
		let accepted = v.verdict == firewall.ACCEPTED;
		let families = map(filter(flows, (f) => f.kind == flow.kind), (f) => f.family);
		add(accepted ? 'ok' : 'warn', 'firewall', `firewall: ${FLOWS[flow.kind](flow)} from ${flow_source(flow, v.zone)}: ` +
			flow_outcome(cfg, flow, v), (flow.option != null) ? { option: flow.option } : null,
			accepted ? null : firewall.fix(flow, v.zone, families));
	}
}

// loaded: config.load's result. obs: what the system looked like, or null for the
// config alone: { enabled, wireguard: the `wireguard status` Result or null when not
// read, routes: { <section>: relay.guard verdict }, discovery_route: on a spoke, the
// route_get Result for the discovery host, null when it is a name; interfaces: the
// WireGuard interfaces of /etc/config/network, { <name>: { addresses, listen_port } };
// firewall: /etc/config/firewall as firewall.verdict reads it, with `found` false when
// there is none, or null when not read }.
export function findings(loaded, obs) {
	let list = [];
	let add = (level, subject, message, about, fix) =>
		push(list, { level: level, subject: subject, ...(about ?? {}), message: message, ...(fix ? { fix: fix } : {}) });

	if (!loaded.ok) {
		let option = failed_option(loaded);
		add('fail', 'config', `config: ${explain(loaded)}`, option ? { option: option } : null);
		return list;
	}
	check_config(loaded.data, add);
	if (obs != null) {
		check_enabled(obs.enabled, add);
		check_substrate(loaded.data, obs, add);
		check_firewall(loaded.data, obs, add);
	}
	return list;
};

export function passed(list) {
	return length(filter(list, (f) => f.level == 'fail')) == 0;
};

function indented(text) {
	return join('', map(split(text, '\n'), (line) => `        ${line}\n`));
}

function render_fix(fix) {
	return `      add it with:\n${indented(fix.uci)}      or in /etc/config/firewall:\n${indented(fix.config)}`;
}

export function render(list) {
	return join('', map(list, (f) => `${LABELS[f.level]}  ${f.message}\n` + (f.fix ? render_fix(f.fix) : '')));
};

function wireguard_interfaces(uci) {
	let out = {};
	uci.foreach('network', 'interface', (s) => {
		if (s.proto != 'wireguard')
			return;
		let list = (type(s.addresses) == 'array') ? s.addresses : split(s.addresses ?? '', /\s+/);
		out[s['.name']] = { addresses: map(list, (a) => endpoint.canonical_ip(split(a, '/')[0])), listen_port: s.listen_port };
	});
	return out;
}

// fw4 includes these into its ruleset, where they may add to its input chains.
const NFT_INCLUDES = [ '/etc/nftables.d/*.nft', '/usr/share/nftables.d/ruleset-*/*.nft', '/usr/share/nftables.d/table-*/*.nft',
	'/usr/share/nftables.d/chain-*/input*/*.nft' ];

// Anything but comments and blank lines may be a rule, and so may a file that cannot be read.
function holds_rules(text) {
	return text == null || match(text, /(^|\n)[ \t]*[^#[:space:]]/) != null;
}

function custom_rules(fs, includes) {
	return includes > 0 || length(filter(fs?.glob(...NFT_INCLUDES) ?? [], (path) => holds_rules(fs.readfile(path)))) > 0;
}

function firewall_config(uci, fs) {
	let fw = { found: false, defaults: null, zones: [], rules: [], custom: false };
	let includes = 0;
	uci.foreach('firewall', null, (s) => {
		fw.found = true;
		if (s['.type'] == 'defaults')
			fw.defaults ??= s;
		else if (s['.type'] == 'zone')
			push(fw.zones, s);
		else if (s['.type'] == 'rule')
			push(fw.rules, s);
		else if (s['.type'] == 'include' && !(s.enabled in DISABLED))
			includes++;
	});
	fw.custom = fw.found && custom_rules(fs, includes);
	return fw;
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
		interfaces: wireguard_interfaces(deps.uci),
		firewall: firewall_config(deps.uci, deps.fs),
	};
}

export function run(deps, opts) {
	let loaded = config.load(deps);
	let obs = (loaded.ok && !opts?.config_only) ? observe(deps, loaded.data) : null;
	let list = findings(loaded, obs);
	return { ok: passed(list), findings: list, report: render(list) };
};
