import { describe, it, assert } from 'utest';
import * as fw from 'wgpathd.firewall';
import * as h from 'lib.helpers';

const TUNNEL   = { kind: 'tunnel', option: 'mesh_iface', family: 4, proto: 'icmp', port: null, iface: 'wg_mesh' };
const TUNNEL6  = { ...TUNNEL, family: 6 };
const RELAY    = { kind: 'relay', option: 'hub_iface', family: 4, proto: 'udp', port: 51820, iface: 'wg_hub' };
const UNDERLAY = { kind: 'underlay', family: 6, proto: 'icmp', zone: 'wan' };

// The mesh and hub interfaces in a zone that rejects input, then the rules given.
function config(rules, opts) {
	return {
		defaults: { '.type': 'defaults', input: 'REJECT', output: 'ACCEPT', forward: 'REJECT' },
		zones: opts?.zones ?? [ h.zone('wan', [ 'wan', 'wan6' ], 'REJECT'), h.zone('vpn', [ 'wg_mesh', 'wg_hub' ], 'REJECT') ],
		rules: rules,
		custom: opts?.custom ?? false,
	};
}

function rule(options) {
	return { '.type': 'rule', src: 'vpn', target: 'ACCEPT', ...options };
}

function verdict_of(rules, flow, opts) {
	return fw.verdict(config(rules, opts), flow).verdict;
}

// Each case: [ rule options, flow, verdict ].
function assert_cases(cases) {
	for (let c in cases)
		assert.match(c[2], verdict_of([ rule(c[0]) ], c[1]), sprintf('%J for %s', c[0], c[1].kind));
}

describe('firewall: what each role needs', () => {
	let ifaces = {
		wg_mesh: { addresses: [ '10.20.0.11' ], listen_port: '51820' },
		wg_hub:  { addresses: [ '10.10.0.11' ] },
	};
	let spoke = { role: 'spoke', mesh_iface: 'wg_mesh', hub_iface: 'wg_hub' };

	it('asks a spoke for the tunnel probe, relayed packets at the mesh listen port, and the underlay probe', () => {
		assert.match([ TUNNEL, RELAY, UNDERLAY ], fw.needs(spoke, ifaces));
	});

	it('asks for the tunnel probe in each family of the mesh addresses, IPv4 without any', () => {
		let dual = { ...ifaces, wg_mesh: { addresses: [ 'fd00:2::11', '10.20.0.11' ], listen_port: '51820' } };
		assert.match([ TUNNEL, TUNNEL6 ], slice(fw.needs(spoke, dual), 0, 2));
		assert.match([ TUNNEL ], slice(fw.needs(spoke, { wg_hub: ifaces.wg_hub }), 0, 1));
	});

	it('leaves the relay port unknown when the mesh interface has no listen_port', () => {
		let random = { ...ifaces, wg_mesh: { addresses: [ '10.20.0.11' ] } };
		assert.match({ ...RELAY, port: null }, fw.needs(spoke, random)[1]);
	});

	it('asks a hub for its port on the WireGuard interface that holds serve_addr, and nothing without one', () => {
		let hub = { role: 'hub', read_iface: 'wg_mesh', serve_addr: '10.10.0.1', serve_port: '7780' };
		let hub_ifaces = { wg_mesh: { addresses: [ '10.20.0.1' ] }, wg_hub: { addresses: [ '10.10.0.1' ] } };
		assert.match([ { kind: 'discovery', option: 'serve_port', family: 4, proto: 'tcp', port: 7780, iface: 'wg_hub' } ],
			fw.needs(hub, hub_ifaces));
		assert.match([], fw.needs({ ...hub, serve_addr: '192.0.2.1' }, hub_ifaces));
	});
});

describe('firewall: a rule of the zone', () => {
	it('accepts with the rules the how-to adds, and misses without them', () => {
		let rules = h.spoke_rules('vpn');
		assert.match({ verdict: fw.ACCEPTED, zone: 'vpn' }, fw.verdict(config(rules), TUNNEL));
		assert.match({ verdict: fw.ACCEPTED, zone: 'vpn' }, fw.verdict(config(rules), RELAY));
		assert.match({ verdict: fw.MISSING, zone: 'vpn', reason: fw.NO_RULE }, fw.verdict(config([]), TUNNEL));
	});

	it('takes a target in any case or shortened, and only accept, reject or drop as a verdict', () => {
		assert_cases([
			[ { proto: 'udp', target: 'accept' }, RELAY, fw.ACCEPTED ],
			[ { proto: 'udp', target: 'acc' }, RELAY, fw.ACCEPTED ],
			[ { proto: 'udp', target: 'NOTRACK' }, RELAY, fw.MISSING ],
			[ { proto: 'udp', target: null }, RELAY, fw.MISSING ],
		]);
	});

	it('skips a disabled rule, or one whose enabled is unreadable', () => {
		assert_cases([
			[ { proto: 'udp', enabled: '0' }, RELAY, fw.MISSING ],
			[ { proto: 'udp', enabled: 'off' }, RELAY, fw.MISSING ],
			[ { proto: 'udp', enabled: 'maybe' }, RELAY, fw.MISSING ],
			[ { proto: 'udp', enabled: 'yes' }, RELAY, fw.ACCEPTED ],
		]);
	});

	it('applies to input from its own zone or any, not to another zone, forwarding or output', () => {
		assert_cases([
			[ { proto: 'udp', src: 'wan' }, RELAY, fw.MISSING ],
			[ { proto: 'udp', src: '*' }, RELAY, fw.ACCEPTED ],
			[ { proto: 'udp', dest: 'lan' }, RELAY, fw.MISSING ],
			[ { proto: 'udp', src: null, dest: 'vpn' }, RELAY, fw.MISSING ],
		]);
	});

	it('reads the protocol as fw4 does: lists, aliases, numbers, TCP and UDP when unset', () => {
		assert_cases([
			[ { proto: [ 'tcp', 'udp' ] }, RELAY, fw.ACCEPTED ],
			[ { proto: 'tcp udp' }, RELAY, fw.ACCEPTED ],
			[ { proto: 'tcpudp' }, RELAY, fw.ACCEPTED ],
			[ { proto: null }, RELAY, fw.ACCEPTED ],
			[ { proto: '17' }, RELAY, fw.ACCEPTED ],
			[ { proto: 'all' }, RELAY, fw.ACCEPTED ],
			[ { proto: 'UDP' }, RELAY, fw.ACCEPTED ],
			[ { proto: 'tcp' }, RELAY, fw.MISSING ],
			[ { proto: null }, TUNNEL, fw.MISSING ],
			[ { proto: 'icmp' }, TUNNEL, fw.ACCEPTED ],
			[ { proto: '1' }, TUNNEL, fw.ACCEPTED ],
			[ { proto: 'icmp' }, TUNNEL6, fw.ACCEPTED ],
			[ { proto: 'icmpv6' }, TUNNEL6, fw.ACCEPTED ],
			[ { proto: 'ipv6-icmp' }, TUNNEL6, fw.ACCEPTED ],
			[ { proto: 'icmpv6' }, TUNNEL, fw.MISSING ],
			[ { proto: '!tcp' }, RELAY, fw.UNSURE ],
		]);
	});

	it('matches the port singly, as a range, in a list, and ignores ports for ICMP', () => {
		assert_cases([
			[ { proto: 'udp', dest_port: '51820' }, RELAY, fw.ACCEPTED ],
			[ { proto: 'udp', dest_port: '51000-52000' }, RELAY, fw.ACCEPTED ],
			[ { proto: 'udp', dest_port: '51000:52000' }, RELAY, fw.ACCEPTED ],
			[ { proto: 'udp', dest_port: [ '53', '51820' ] }, RELAY, fw.ACCEPTED ],
			[ { proto: 'udp', dest_port: '53 51820' }, RELAY, fw.ACCEPTED ],
			[ { proto: 'udp', dest_port: '51821' }, RELAY, fw.MISSING ],
			[ { proto: 'udp', dest_port: '51821-51830' }, RELAY, fw.MISSING ],
			[ { proto: 'udp', dest_port: '!53' }, RELAY, fw.UNSURE ],
			[ { proto: 'udp', dest_port: 'wireguard' }, RELAY, fw.UNSURE ],
			[ { proto: 'icmp', dest_port: '53' }, TUNNEL, fw.ACCEPTED ],
			[ { proto: 'all', dest_port: '53' }, RELAY, fw.ACCEPTED ],
		]);
	});

	it('matches an echo request by name, alias or number, and all types when none is given', () => {
		assert_cases([
			[ { proto: 'icmp', icmp_type: 'echo-request' }, TUNNEL, fw.ACCEPTED ],
			[ { proto: 'icmp', icmp_type: 'ping' }, TUNNEL, fw.ACCEPTED ],
			[ { proto: 'icmp', icmp_type: '8' }, TUNNEL, fw.ACCEPTED ],
			[ { proto: 'icmp', icmp_type: '8/0' }, TUNNEL, fw.ACCEPTED ],
			[ { proto: 'icmp', icmp_type: '8/3' }, TUNNEL, fw.MISSING ],
			[ { proto: 'icmp', icmp_type: '128' }, TUNNEL, fw.MISSING ],
			[ { proto: 'icmp', icmp_type: '128' }, TUNNEL6, fw.ACCEPTED ],
			[ { proto: 'icmp', icmp_type: [ 'echo-reply', 'echo-request' ] }, TUNNEL, fw.ACCEPTED ],
			[ { proto: 'icmp', icmp_type: [ 'echo-reply' ], family: 'ipv4' }, TUNNEL, fw.MISSING ],
		]);
	});

	it('cannot tell an ICMP rule for both families that names only other types', () => {
		assert_cases([ [ { proto: 'icmp', icmp_type: 'router-solicitation' }, TUNNEL, fw.UNSURE ] ]);
	});

	it('keeps a rule to its family, and skips one whose family is unreadable', () => {
		assert_cases([
			[ { proto: 'icmp', family: 'ipv6' }, TUNNEL, fw.MISSING ],
			[ { proto: 'icmp', family: 'ipv4' }, TUNNEL, fw.ACCEPTED ],
			[ { proto: 'icmp', family: 'any' }, TUNNEL, fw.ACCEPTED ],
			[ { proto: 'icmp', family: 'ip4' }, TUNNEL, fw.ACCEPTED ],
			[ { proto: 'udp', family: 'ipv6' }, RELAY, fw.MISSING ],
			[ { proto: 'icmp', family: 'bogus' }, TUNNEL, fw.MISSING ],
		]);
	});

	it('cannot confirm a rule narrowed by an address, a mark, a set, a time or a device', () => {
		for (let narrowing in [ { src_ip: '10.0.0.0/8' }, { dest_ip: '10.20.0.11' }, { src_mac: '00:11:22:33:44:55' },
			{ src_port: '51820' }, { ipset: 'peers' }, { mark: '0x1' }, { start_time: '08:00:00' }, { weekdays: 'Mon' },
			{ device: 'wg_hub' }, { helper: 'ftp' }, { extra: '-m foo' } ])
			assert.match(fw.UNSURE, verdict_of([ rule({ proto: 'udp', ...narrowing }) ], RELAY), narrowing);
	});

	it('takes a rate-limited rule as accepting', () => {
		assert_cases([ [ { proto: 'udp', limit: '10/sec' }, RELAY, fw.ACCEPTED ] ]);
	});
});

describe('firewall: the order of rules and the zone policy', () => {
	let reject_udp = rule({ proto: 'udp', target: 'REJECT' });
	let accept_udp = rule({ proto: 'udp' });

	it('lets the first rule that decides win, rules from any zone first', () => {
		assert.match({ verdict: fw.MISSING, zone: 'vpn', reason: fw.REJECTED }, fw.verdict(config([ reject_udp, accept_udp ]), RELAY));
		assert.match(fw.ACCEPTED, verdict_of([ accept_udp, reject_udp ], RELAY));
		assert.match(fw.ACCEPTED, verdict_of([ reject_udp, { ...accept_udp, src: '*' } ], RELAY));
		assert.match(fw.MISSING, verdict_of([ accept_udp, rule({ proto: 'udp', src: '*', target: 'DROP' }) ], RELAY));
	});

	it('cannot confirm a verdict that a rule it cannot follow may come before', () => {
		let narrowed = (target) => rule({ proto: 'udp', src_ip: '10.0.0.0/8', target: target });
		assert.match(fw.UNSURE, verdict_of([ narrowed('REJECT'), accept_udp ], RELAY));
		assert.match(fw.UNSURE, verdict_of([ narrowed('ACCEPT'), reject_udp ], RELAY));
		assert.match(fw.UNSURE, verdict_of([ narrowed('ACCEPT') ], RELAY));
		assert.match(fw.ACCEPTED, verdict_of([ narrowed('ACCEPT'), accept_udp ], RELAY));
		assert.match(fw.MISSING, verdict_of([ narrowed('REJECT'), reject_udp ], RELAY));
	});

	it('falls to the zone\'s input policy, or the default one when the zone has none', () => {
		let zones = (input) => ({ zones: [ h.zone('vpn', [ 'wg_mesh', 'wg_hub' ], input) ] });
		assert.match(fw.ACCEPTED, verdict_of([], RELAY, zones('ACCEPT')));
		assert.match(fw.MISSING, verdict_of([], RELAY, zones('DROP')));
		let open = { ...config([], zones(null)), defaults: { input: 'ACCEPT' } };
		assert.match(fw.ACCEPTED, fw.verdict(open, RELAY).verdict);
		assert.match(fw.MISSING, fw.verdict({ ...open, defaults: null }, RELAY).verdict);
	});
});

describe('firewall: the zone of an interface', () => {
	it('takes the first zone that lists the interface, in a list or in words', () => {
		let zones = [ h.zone('lan', 'lan wg_hub', 'ACCEPT'), h.zone('vpn', [ 'wg_hub' ], 'REJECT') ];
		assert.match({ verdict: fw.ACCEPTED, zone: 'lan' }, fw.verdict(config([], { zones: zones }), RELAY));
	});

	it('skips a disabled zone, and one fw4 would refuse by its name', () => {
		let hostile = '<b>vpn</b>';
		let zones = [ { ...h.zone('lan', [ 'wg_hub' ], 'ACCEPT'), enabled: '0' }, h.zone(hostile, [ 'wg_hub' ], 'ACCEPT'),
			h.zone('vpn', [ 'wg_hub' ], 'REJECT') ];
		assert.match({ verdict: fw.MISSING, zone: 'vpn', reason: fw.NO_RULE }, fw.verdict(config([], { zones: zones }), RELAY));
	});

	it('answers an interface in no zone by the rules from any zone and the default policy', () => {
		let zones = { zones: [ h.zone('wan', [ 'wan' ], 'REJECT') ] };
		assert.match({ verdict: fw.MISSING, zone: null, reason: fw.NO_ZONE }, fw.verdict(config([], zones), RELAY));
		assert.match(fw.ACCEPTED, verdict_of([ rule({ proto: 'udp', src: '*' }) ], RELAY, zones));
	});

	it('cannot confirm a zone with options it does not follow, or one a zone by device or subnet may come before', () => {
		let cases = [
			[ h.zone('vpn', [ 'wg_hub' ], 'ACCEPT', { extra_src: '-m foo' }) ],
			[ h.zone('dev', null, 'REJECT', { device: 'wg+' }), h.zone('vpn', [ 'wg_hub' ], 'ACCEPT') ],
			[ h.zone('net', null, 'REJECT', { subnet: '10.10.0.0/24' }) ],
			[ h.zone('vpn', [ 'wg_hub' ], 'ACCEPT', { family: 'ipv6' }) ],
		];
		let reasons = map(cases, (zones) => fw.verdict(config([], { zones: zones }), RELAY));
		assert.match([ fw.CONDITIONS, fw.MATCHED_BY, fw.MATCHED_BY, fw.ZONE_FAMILY ], map(reasons, (v) => v.reason));
		assert.match([ fw.UNSURE ], uniq(map(reasons, (v) => v.verdict)));
	});

	it('cannot confirm a flow missing from the rules when custom nftables rules may add it', () => {
		assert.match({ verdict: fw.UNSURE, zone: 'vpn', reason: fw.CUSTOM }, fw.verdict(config([], { custom: true }), RELAY));
		assert.match(fw.ACCEPTED, verdict_of(h.spoke_rules('vpn'), RELAY, { custom: true }));
	});

	it('cannot confirm relayed packets without a port', () => {
		assert.match({ verdict: fw.UNSURE, zone: 'vpn', reason: fw.NO_PORT },
			fw.verdict(config(h.spoke_rules('vpn')), { ...RELAY, port: null }));
	});
});

describe('firewall: the underlay probe from the wan zone', () => {
	it('is accepted by OpenWrt\'s default rule, and missing when it is disabled', () => {
		assert.match(fw.ACCEPTED, verdict_of([ h.ALLOW_ICMPV6_INPUT ], UNDERLAY));
		assert.match(fw.MISSING, verdict_of([ { ...h.ALLOW_ICMPV6_INPUT, enabled: '0' } ], UNDERLAY));
		assert.match(fw.MISSING, verdict_of([ { ...h.ALLOW_ICMPV6_INPUT, icmp_type: [ 'packet-too-big' ] } ], UNDERLAY));
	});

	it('cannot confirm it without a zone named wan', () => {
		let zones = { zones: [ h.zone('vpn', [ 'wg_mesh', 'wg_hub' ], 'REJECT') ] };
		assert.match({ verdict: fw.UNSURE, zone: null, reason: fw.NOT_FOUND }, fw.verdict(config([ h.ALLOW_ICMPV6_INPUT ], zones), UNDERLAY));
	});
});

describe('firewall: the rule to add', () => {
	it('gives the relay rule as uci commands and as a section', () => {
		assert.match({
			uci: "uci add firewall rule\n" +
				"uci set firewall.@rule[-1].name='Allow-wgpathd-relay'\n" +
				"uci set firewall.@rule[-1].src='vpn'\n" +
				"uci set firewall.@rule[-1].proto='udp'\n" +
				"uci set firewall.@rule[-1].dest_port='51820'\n" +
				"uci set firewall.@rule[-1].target='ACCEPT'\n" +
				"uci commit firewall\n" +
				"service firewall reload",
			config: "config rule\n" +
				"\toption name 'Allow-wgpathd-relay'\n" +
				"\toption src 'vpn'\n" +
				"\toption proto 'udp'\n" +
				"\toption dest_port '51820'\n" +
				"\toption target 'ACCEPT'",
		}, fw.fix(RELAY, 'vpn'));
	});

	it('gives one tunnel probe rule for its family, or for both', () => {
		assert.match("config rule\n\toption name 'Allow-wgpathd-tunnel-probe'\n\toption src 'mgmt'\n\toption proto 'icmp'\n" +
			"\toption icmp_type 'echo-request'\n\toption family 'ipv4'\n\toption target 'ACCEPT'", fw.fix(TUNNEL, 'mgmt').config);
		assert.match(false, index(fw.fix(TUNNEL6, 'mgmt', [ 4, 6 ]).config, 'family') >= 0);
		assert.match(true, index(fw.fix(TUNNEL6, 'mgmt', [ 6 ]).config, "option family 'ipv6'") >= 0);
	});

	it('gives the discovery rule for the hub\'s port', () => {
		let discovery = { kind: 'discovery', option: 'serve_port', family: 4, proto: 'tcp', port: 7780, iface: 'wg_hub' };
		assert.match(true, index(fw.fix(discovery, 'vpn').uci, "uci set firewall.@rule[-1].dest_port='7780'") >= 0);
	});

	it('gives none without a zone or a port, nor for the underlay probe', () => {
		assert.match([ null, null, null ], [ fw.fix(RELAY, null), fw.fix({ ...RELAY, port: null }, 'vpn'), fw.fix(UNDERLAY, 'wan') ]);
	});
});
