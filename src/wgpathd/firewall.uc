'use strict';

// What wgpathd needs the firewall to accept, and whether /etc/config/firewall does,
// read the way fw4 reads it. Best effort: a rule or zone it cannot follow, or custom
// nftables rules, make the answer UNSURE, never MISSING.
//
// A flow is { kind, option, family: 4 or 6, proto: 'icmp' (an echo request), 'udp' or
// 'tcp', port, and iface: the interface it arrives on, or zone: the zone it comes from }.

import { family as address_family } from 'wgpathd.icmp';

export const ACCEPTED = 'accepted';
export const MISSING  = 'missing';
export const UNSURE   = 'unsure';

// Why a flow is MISSING or UNSURE.
export const NO_RULE     = 'no rule';
export const REJECTED    = 'rejected';
export const NO_ZONE     = 'no zone';
export const CONDITIONS  = 'conditions';
export const CUSTOM      = 'custom';
export const MATCHED_BY  = 'matched by device or subnet';
export const ZONE_FAMILY = 'zone family';
export const NO_PORT     = 'no port';
export const NOT_FOUND   = 'zone not found';

// fw4 skips a zone with any other name, so a zone name that reaches a message is plain.
const IDENTIFIER = /^[a-zA-Z_.][a-zA-Z0-9\/_.-]*$/;

// Rule options that narrow what a rule matches in ways not followed here.
const NARROWING = [ 'src_ip', 'src_mac', 'src_port', 'dest_ip', 'device', 'ipset', 'helper', 'mark', 'dscp',
	'start_date', 'stop_date', 'start_time', 'stop_time', 'weekdays', 'monthdays', 'extra' ];

const POLICIES = [ 'accept', 'reject', 'drop' ];
const ECHO_TYPE = { [4]: 8, [6]: 128 };

// How much of a flow a rule or one of its options covers.
const NO = 0, MAYBE = 1, YES = 2;

// fw4 splits an option's text at blanks, but takes each item of a list whole.
function items(v) {
	if (type(v) == 'array')
		return v;
	let s = trim(`${v ?? ''}`);
	return (s == '') ? [] : split(s, /[ \t]+/);
}

function is_set(v) {
	return length(items(v)) > 0;
}

// fw4 takes any leading part of a choice, in any case.
function choice(v, choices) {
	if (type(v) != 'string')
		return null;
	for (let c in choices)
		if (substr(c, 0, length(v)) == lc(v))
			return c;
	return null;
}

// fw4 skips a section whose `enabled` it cannot read.
function enabled(s) {
	return s.enabled == null || s.enabled in [ '1', 'on', 'true', 'yes' ];
}

// 0 for both families, null when unreadable.
function family_of(v) {
	if (v == null || v in [ 'any', 'all', '*' ])
		return 0;
	if (v == 'inet' || index(v, '4') >= 0)
		return 4;
	return (index(v, '6') >= 0) ? 6 : null;
}

const PROTO_NAMES = {
	all: 'any', any: 'any', '*': 'any', '1': 'icmp', icmp: 'icmp', '58': 'icmpv6', icmpv6: 'icmpv6',
	'ipv6-icmp': 'icmpv6', '6': 'tcp', '17': 'udp',
};

// The protocols a rule names, TCP and UDP when unset as in fw4; null when one is inverted.
function protocols(v) {
	let out = [];
	for (let p in items(v ?? 'tcpudp')) {
		p = lc(p);
		if (substr(p, 0, 1) == '!')
			return null;
		if (p == 'tcpudp')
			push(out, 'tcp', 'udp');
		else
			push(out, PROTO_NAMES[p] ?? p);
	}
	return out;
}

function port_covers(v, port) {
	let found = NO;
	if (!is_set(v))
		return YES;
	for (let p in items(v)) {
		let m = match(p, /^([0-9]{1,5})([-:]([0-9]{1,5}))?$/);
		if (m == null)
			return MAYBE;
		if (port >= +m[1] && port <= +(m[3] ?? m[1]))
			found = YES;
	}
	return found;
}

// A type named otherwise may be one fw4 knows for one family only, and when a rule for
// both families names none of the other family's types, fw4 accepts every type of it.
function echo_covers(v, family, rule_family) {
	let found = NO;
	if (!is_set(v))
		return YES;
	for (let t in items(v)) {
		let m = match(t, /^([0-9]+)(\/([0-9]+))?$/);
		if (t in [ 'echo-request', 'ping' ] || (m && +m[1] == ECHO_TYPE[family] && (m[3] == null || +m[3] == 0)))
			return YES;
		if (m == null && rule_family == 0)
			found = MAYBE;
	}
	return found;
}

// A rule for ICMP matches ICMPv6 too unless its family says otherwise; the ports of a
// rule apply to its TCP and UDP only.
function proto_covers(rule, family, flow) {
	let protos = protocols(rule.proto);
	if (protos == null)
		return MAYBE;
	let best = NO;
	for (let p in protos) {
		let res = NO;
		if (p == 'any')
			res = YES;
		else if (flow.proto == 'icmp' && (p == 'icmp' || (p == 'icmpv6' && flow.family == 6)))
			res = echo_covers(rule.icmp_type, flow.family, family);
		else if (p == flow.proto)
			res = port_covers(rule.dest_port, flow.port);
		best = max(best, res);
	}
	return best;
}

// How a rule treats the flow: null when it does not apply to it, else { accept, sure }.
// Only accept, reject and drop decide; a rule without its own family takes its zone's.
function effect(rule, flow, zone_family) {
	if (!enabled(rule))
		return null;
	let target = choice(rule.target, POLICIES);
	let family = family_of(rule.family);
	if (target == null || family == null)
		return null;
	family ||= zone_family;
	if (family && family != flow.family)
		return null;
	let covers = proto_covers(rule, family, flow);
	if (covers == NO)
		return null;
	let narrowed = length(filter(NARROWING, (opt) => is_set(rule[opt]))) > 0;
	return { accept: target == 'accept', sure: covers == YES && !narrowed };
}

function input_rule(rule, src) {
	return rule.src == src && !is_set(rule.dest);
}

// The rules on the flow's way in fw4's order, those from any zone first, then the
// policy: the first sure verdict decides, unless a rule not followed came before.
function walk(rules, flow, zone, policy) {
	let maybe = { accept: false, reject: false };
	let decided = function(accept, reason) {
		if (accept)
			return maybe.reject ? { verdict: UNSURE, reason: CONDITIONS } : { verdict: ACCEPTED };
		return maybe.accept ? { verdict: UNSURE, reason: CONDITIONS } : { verdict: MISSING, reason: reason };
	};
	let chain = [
		...filter(rules, (r) => input_rule(r, '*')),
		...(zone ? filter(rules, (r) => input_rule(r, zone.name)) : []),
	];
	for (let rule in chain) {
		let e = effect(rule, flow, zone ? family_of(zone.family) : 0);
		if (e == null)
			continue;
		if (e.sure)
			return decided(e.accept, REJECTED);
		maybe[e.accept ? 'accept' : 'reject'] = true;
	}
	return decided(choice(policy ?? 'drop', POLICIES) == 'accept', zone ? NO_RULE : NO_ZONE);
}

// The zone fw4 sends the flow to: the first that lists its interface, or has its name.
function zone_for(zones, flow) {
	let by_address = false;
	for (let z in zones) {
		let listed = (flow.zone != null) ? z.name == flow.zone : flow.iface in items(z.network);
		if (listed) {
			let family = family_of(z.family) ?? 0;
			if (family && family != flow.family)
				return { zone: z, unsure: ZONE_FAMILY };
			if (is_set(z.extra_src) || is_set(z.extra))
				return { zone: z, unsure: CONDITIONS };
			return { zone: z, unsure: by_address ? MATCHED_BY : null };
		}
		by_address ||= is_set(z.device) || is_set(z.subnet);
	}
	return { zone: null, unsure: (flow.zone != null) ? NOT_FOUND : (by_address ? MATCHED_BY : null) };
}

// fw: { defaults, zones, rules, custom }: the sections of /etc/config/firewall, and
// whether custom nftables rules may add to them. Returns { verdict, zone, reason }:
// zone is the name of the flow's zone, or null.
export function verdict(fw, flow) {
	let zones = filter(fw.zones, (z) => enabled(z) && match(z.name, IDENTIFIER) != null);
	let found = zone_for(zones, flow);
	let zone = found.zone?.name;
	if (found.unsure != null)
		return { verdict: UNSURE, zone: zone, reason: found.unsure };
	if (flow.proto != 'icmp' && flow.port == null)
		return { verdict: UNSURE, zone: zone, reason: NO_PORT };
	let res = walk(fw.rules, flow, found.zone, found.zone?.input ?? fw.defaults?.input);
	if (res.verdict == MISSING && fw.custom)
		return { verdict: UNSURE, zone: zone, reason: CUSTOM };
	return { ...res, zone: zone };
};

// IPv4 when the interface has no address to go by.
function families(iface) {
	let out = uniq(filter(map(iface?.addresses ?? [], address_family), (f) => f != null));
	return length(out) ? sort(out) : [ 4 ];
}

function port_number(s) {
	return (type(s) == 'string' && match(s, /^[0-9]{1,5}$/) && +s <= 65535) ? +s : null;
}

// The flows a role needs accepted, one per address family. ifaces: { <name>: { addresses,
// listen_port } } for the WireGuard interfaces of /etc/config/network. Probes come to
// this router's addresses on the mesh interface, and relayed packets to its address on
// the hub interface, at the listen port of the mesh interface.
export function needs(cfg, ifaces) {
	let per_family = (kind, option, iface, proto, port) => map(families(ifaces[iface]), (family) =>
		({ kind: kind, option: option, family: family, proto: proto, port: port, iface: iface }));
	if (cfg.role == 'hub') {
		let holder = filter(sort(keys(ifaces)), (name) => cfg.serve_addr in ifaces[name].addresses)[0];
		return (holder == null) ? [] : [ { kind: 'discovery', option: 'serve_port', family: address_family(cfg.serve_addr),
			proto: 'tcp', port: +cfg.serve_port, iface: holder } ];
	}
	return [
		...per_family('tunnel', 'mesh_iface', cfg.mesh_iface, 'icmp', null),
		...per_family('relay', 'hub_iface', cfg.hub_iface, 'udp', port_number(ifaces[cfg.mesh_iface]?.listen_port)),
		{ kind: 'underlay', family: 6, proto: 'icmp', zone: 'wan' },
	];
};

const RULE_NAMES = { tunnel: 'Allow-wgpathd-tunnel-probe', relay: 'Allow-wgpathd-relay', discovery: 'Allow-wgpathd-discovery' };

// Only an ICMP rule needs a family: one for UDP or TCP names no address.
function rule_options(flow, zone, families) {
	let opts = [ [ 'name', RULE_NAMES[flow.kind] ], [ 'src', zone ], [ 'proto', flow.proto ] ];
	if (flow.proto == 'icmp') {
		push(opts, [ 'icmp_type', 'echo-request' ]);
		if (length(families) == 1)
			push(opts, [ 'family', (families[0] == 6) ? 'ipv6' : 'ipv4' ]);
	}
	else
		push(opts, [ 'dest_port', `${flow.port}` ]);
	push(opts, [ 'target', 'ACCEPT' ]);
	return opts;
}

// The rule that accepts the flow, as uci commands and as a section of
// /etc/config/firewall; null without a zone to name or a port. families: those the
// flow's kind needs, for one ICMP rule to cover them all.
export function fix(flow, zone, families) {
	if (zone == null || RULE_NAMES[flow.kind] == null || (flow.proto != 'icmp' && flow.port == null))
		return null;
	let opts = rule_options(flow, zone, families ?? [ flow.family ]);
	return {
		uci: join('\n', [
			'uci add firewall rule',
			...map(opts, (o) => `uci set firewall.@rule[-1].${o[0]}='${o[1]}'`),
			'uci commit firewall',
			'service firewall reload',
		]),
		config: join('\n', [ 'config rule', ...map(opts, (o) => `\toption ${o[0]} '${o[1]}'`) ]),
	};
};
