import { describe, it, assert } from 'utest';
import * as check from 'wgpathd.check';
import * as Result from 'wgpathd.result';
import * as relay from 'wgpathd.relay';
import * as fw from 'wgpathd.firewall';
import * as h from 'lib.helpers';

const SPOKE_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const HUB  = 'W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=';


const SPOKE_B_PEER = { section: 'spoke_b', pubkey: SPOKE_B, relay: '10.10.0.12:51820', tunnel: '10.20.0.12' };

function spoke(unmanaged, extra) {
	return Result.ok({ role: 'spoke', mesh_iface: 'wg_mesh', hub_iface: 'wg_hub', mode: 'steer', overrides: {}, leftovers: [],
		peers: { managed: [ SPOKE_B_PEER ], unmanaged: unmanaged ?? [], stale: [] }, ...(extra ?? {}) });
}

const HUB_CFG = Result.ok({ role: 'hub', read_iface: 'wg_mesh', serve_addr: '192.0.2.1', serve_port: '7780', overrides: {},
	leftovers: [] });

const WG_UP = Result.ok({ ...h.status_reply('wg_mesh', { [SPOKE_B]: { hs: 0 } }), ...h.status_reply('wg_hub', {}) });

function obs(extra) {
	return { enabled: null, wireguard: null, routes: { spoke_b: { verdict: relay.MANAGED, oif: 'wg_hub' } }, ...(extra ?? {}) };
}

describe('check: findings for the config alone', () => {
	it('names the option a loader error is about', () => {
		let cases = [
			[ Result.err('CONFIG_INVALID_ROLE', 'unset'), { option: 'role' }, "option role must be 'spoke' or 'hub' (is unset)" ],
			[ Result.err('CONFIG_MISSING_OPTION', 'discovery'), { option: 'discovery' }, 'missing option discovery' ],
			[ Result.err('CONFIG_INVALID_OPTION', 'cycle must be a number from 1 to 10'), { option: 'cycle' },
				'option cycle must be a number from 1 to 10' ],
			[ Result.err('INTERFACE_MISSING', 'wg_nope'), {}, 'no interface wg_nope in /etc/config/network' ],
		];
		for (let c in cases)
			assert.match([ { level: 'fail', subject: 'config', ...c[1], message: `config: ${c[2]}` } ],
				check.findings(c[0], obs()), c[0].error);
	});

	it('gives the summary alone without an observation', () => {
		assert.match([ { level: 'ok', subject: 'config', message: 'config: spoke, mode steer, 1 steered peer, 0 not steered' } ],
			check.findings(spoke(), null));
	});

	it('marks an unknown mode and a disabled service on their options', () => {
		let loaded = Result.ok({ ...spoke().data, mode: 'observe', invalid_mode: 'stear' });
		let list = check.findings(loaded, obs({ enabled: 'off' }));
		assert.match([
			{ level: 'warn', subject: 'config', option: 'mode', message: "config: unknown mode 'stear' runs as observe" },
			{ level: 'warn', subject: 'config', option: 'enabled', message: "service disabled (option enabled 'off'): it will not start" },
		], slice(list, 1, 3));
	});

	it('warns about each network section left with the options of an earlier version, in both roles', () => {
		let leftovers = [ { section: 'spoke_b', options: [ 'wgpathd_relay', 'wgpathd_tunnel' ] },
			{ section: 'hub', options: [ 'wgpathd_tunnel' ] } ];
		let expected = [
			{ level: 'warn', subject: 'config', section: 'spoke_b', message: 'config: network section spoke_b: wgpathd_relay and ' +
				'wgpathd_tunnel left over from an earlier version, ignored; run service wgpathd migrate or remove them' },
			{ level: 'warn', subject: 'config', section: 'hub', message: 'config: network section hub: wgpathd_tunnel left over ' +
				'from an earlier version, ignored; run service wgpathd migrate or remove it' },
		];
		assert.match(expected, slice(check.findings(spoke(null, { leftovers: leftovers }), null), 1));
		assert.match(expected, slice(check.findings(Result.ok({ ...HUB_CFG.data, leftovers: leftovers }), null), 1));
	});

	it('warns about peer settings that match no mesh peer, by key', () => {
		let loaded = spoke(null, { peers: { managed: [ SPOKE_B_PEER ], unmanaged: [], stale: [ { pubkey: HUB }, { pubkey: null } ] } });
		assert.match([
			{ level: 'warn', subject: 'peer', public_key: HUB, message: `peer settings for ${HUB}: no such peer in wg_mesh, ignored` },
			{ level: 'warn', subject: 'peer', message: 'peer settings without a public_key: ignored' },
		], slice(check.findings(loaded, null), 1));
	});
});

describe('check: findings for the peers', () => {
	it('marks every peer finding with its section and key, and a bad setting with its option', () => {
		let loaded = spoke([
			{ section: 'hub', pubkey: HUB, reason: 'fixed endpoint' },
			{ section: 'spoke_c', pubkey: null, reason: 'invalid public_key' },
		]);
		assert.match([
			{ level: 'ok', subject: 'peer', section: 'spoke_b', public_key: SPOKE_B,
				message: 'peer spoke_b: relay 10.10.0.12:51820 via wg_hub, probes 10.20.0.12' },
			{ level: 'skip', subject: 'peer', section: 'hub', public_key: HUB,
				message: 'peer hub: not steered (fixed endpoint)' },
			{ level: 'fail', subject: 'peer', section: 'spoke_c', option: 'public_key',
				message: 'peer spoke_c: not steered (invalid public_key)' },
		], slice(check.findings(loaded, obs()), 1));
	});

	it('skips a peer without settings, with a fixed endpoint or not', () => {
		for (let reason in [ 'not configured', 'fixed endpoint' ])
			assert.match({ level: 'skip', subject: 'peer', section: 'hub', public_key: HUB, message: `peer hub: not steered (${reason})` },
				check.findings(spoke([ { section: 'hub', pubkey: HUB, reason: reason } ]), obs())[-1], reason);
	});

	it('fails settings half given, malformed or given twice, marking the option when there is one', () => {
		let cases = {
			'missing relay': 'relay', 'invalid relay': 'relay', 'missing tunnel': 'tunnel', 'invalid tunnel': 'tunnel',
			'configured more than once': null,
		};
		for (let reason, option in cases) {
			let finding = check.findings(spoke([ { section: 'hub', pubkey: HUB, reason: reason } ]), obs())[-1];
			let about = (option != null) ? { option: option } : {};
			assert.match({ level: 'fail', subject: 'peer', section: 'hub', public_key: HUB, ...about,
				message: `peer hub: not steered (${reason})` }, finding, reason);
		}
	});

	it('marks a relay routed into the mesh on relay, and a pending lookup on no option', () => {
		let rejected = check.findings(spoke(), obs({ routes: { spoke_b: { verdict: relay.REJECTED, reason: 'relay routes into wg_mesh' } } }));
		assert.match({ level: 'fail', subject: 'peer', section: 'spoke_b', public_key: SPOKE_B, option: 'relay',
			message: 'peer spoke_b: relay routes into wg_mesh' }, rejected[1]);
		let pending = check.findings(spoke(), obs({ routes: { spoke_b: { verdict: relay.PENDING, reason: 'relay route lookup failed: X' } } }));
		assert.match({ level: 'warn', subject: 'peer', section: 'spoke_b', public_key: SPOKE_B,
			message: 'peer spoke_b: relay route lookup failed: X (retried every cycle)' }, pending[1]);
	});
});


describe('check: findings for the interfaces', () => {
	it('leaves the interfaces out, and whether a peer is in the kernel, when wireguard status was not read', () => {
		let list = check.findings(spoke(), obs());
		assert.match([ 'config', 'peer' ], map(list, (f) => f.subject));
	});

	it('names each interface as its subject', () => {
		let list = check.findings(spoke(), obs({ wireguard: WG_UP }));
		assert.match([
			{ level: 'ok', subject: 'wg_mesh', message: 'wg_mesh: up, 1 peer' },
			{ level: 'ok', subject: 'wg_hub', message: 'wg_hub: up, 0 peers' },
		], slice(list, 1, 3));
	});

	it('says the interfaces were skipped when ubus was unreachable', () => {
		let list = check.findings(spoke(), obs({ wireguard: Result.err('UBUS_CONNECT_FAILED') }));
		assert.match({ level: 'skip', subject: 'ubus', message: 'ubus unavailable: interfaces not checked' }, list[1]);
	});

	it('checks only the read interface of a hub', () => {
		let list = check.findings(HUB_CFG, obs({ routes: {}, wireguard: WG_UP }));
		assert.match([ 'config', 'wg_mesh' ], map(list, (f) => f.subject));
	});
});

describe('check: findings for the firewall', () => {
	const IFACES = {
		wg_mesh: { addresses: [ '10.20.0.11' ], listen_port: '51820' },
		wg_hub:  { addresses: [ '10.10.0.11', '192.0.2.1' ] },
	};

	function firewall(rules, extra) {
		return { found: true, defaults: { input: 'REJECT' }, custom: false, rules: rules,
			zones: [ h.zone('wan', [ 'wan' ], 'REJECT'), h.zone('vpn', [ 'wg_mesh', 'wg_hub' ], 'REJECT') ], ...(extra ?? {}) };
	}

	function of_firewall(loaded, fw, ifaces) {
		return filter(check.findings(loaded, obs({ interfaces: ifaces ?? IFACES, firewall: fw })), (f) => f.subject == 'firewall');
	}

	it('says, last, what the firewall accepts of each flow a spoke needs', () => {
		let list = check.findings(spoke(), obs({ interfaces: IFACES, firewall: firewall([ ...h.spoke_rules('vpn'), h.ALLOW_ICMPV6_INPUT ]) }));
		assert.match([
			{ level: 'ok', subject: 'firewall', option: 'mesh_iface',
				message: 'firewall: ICMP echo-request (tunnel probe) from wg_mesh (zone vpn): accepted' },
			{ level: 'ok', subject: 'firewall', option: 'hub_iface',
				message: 'firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): accepted' },
			{ level: 'ok', subject: 'firewall', message: 'firewall: ICMPv6 echo-request (underlay probe) from zone wan: accepted' },
		], slice(list, -3));
	});

	it('warns about each flow no rule accepts, on its option, with the rule to add', () => {
		let list = of_firewall(spoke(), firewall([]));
		assert.match([ 'warn', 'warn', 'warn' ], map(list, (f) => f.level));
		assert.match({ level: 'warn', subject: 'firewall', option: 'hub_iface',
			message: 'firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): no rule accepts it',
			fix: fw.fix({ kind: 'relay', proto: 'udp', port: 51820 }, 'vpn') }, list[1]);
		assert.match("config rule\n\toption name 'Allow-wgpathd-tunnel-probe'\n\toption src 'vpn'\n\toption proto 'icmp'\n" +
			"\toption icmp_type 'echo-request'\n\toption family 'ipv4'\n\toption target 'ACCEPT'", list[0].fix.config);
		assert.match({ level: 'warn', subject: 'firewall',
			message: "firewall: ICMPv6 echo-request (underlay probe) from zone wan: no rule accepts it: " +
				"restore OpenWrt's default rule Allow-ICMPv6-Input" }, list[2]);
	});

	it('asks for one tunnel probe rule that covers every family of the mesh addresses', () => {
		let dual = { ...IFACES, wg_mesh: { addresses: [ '10.20.0.11', 'fd00:2::11' ], listen_port: '51820' } };
		let list = of_firewall(spoke(), firewall(h.spoke_rules('vpn')), dual);
		assert.match([ 'ok', 'warn' ], [ list[0].level, list[1].level ]);
		assert.match('firewall: ICMPv6 echo-request (tunnel probe) from wg_mesh (zone vpn): no rule accepts it', list[1].message);
		assert.match(false, index(list[1].fix.config, 'family') >= 0);
	});

	it('says when a rule rejects a flow first, or its interface is in no zone', () => {
		let reject = { '.type': 'rule', src: 'vpn', proto: 'udp', target: 'REJECT' };
		assert.match('firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): a rule rejects it before any accepts it',
			of_firewall(spoke(), firewall([ reject, ...h.spoke_rules('vpn') ]))[1].message);
		let list = of_firewall(spoke(), firewall([], { zones: [ h.zone('wan', [ 'wan' ], 'REJECT') ] }));
		assert.match({ level: 'warn', subject: 'firewall', option: 'mesh_iface',
			message: 'firewall: ICMP echo-request (tunnel probe) from wg_mesh (no zone): no rule accepts it; put wg_mesh in a firewall zone' },
			list[0]);
	});

	it('says why it could not confirm a flow, and still gives the rule to add when it can', () => {
		let narrowed = { '.type': 'rule', src: 'vpn', proto: 'udp', src_ip: '10.10.0.0/24', target: 'ACCEPT' };
		let messages = (fw_, ifaces) => map(of_firewall(spoke(), fw_, ifaces), (f) => f.message);
		assert.match('firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): could not confirm, ' +
			'a rule or zone option this check does not follow applies', messages(firewall([ narrowed ]))[1]);
		assert.match('firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): could not confirm, ' +
			'the firewall has custom nftables rules', messages(firewall([], { custom: true }))[1]);
		let by_subnet = [ h.zone('net', null, 'REJECT', { subnet: '10.20.0.0/24' }), h.zone('vpn', [ 'wg_mesh', 'wg_hub' ], 'REJECT') ];
		assert.match('firewall: ICMP echo-request (tunnel probe) from wg_mesh (zone vpn): could not confirm, ' +
			'a zone may take it by device or subnet', messages(firewall([], { zones: by_subnet }))[0]);
		let v6_only = [ h.zone('vpn', [ 'wg_mesh', 'wg_hub' ], 'REJECT', { family: 'ipv6' }) ];
		assert.match('firewall: ICMP echo-request (tunnel probe) from wg_mesh (zone vpn): could not confirm, ' +
			'zone vpn is not for IPv4', messages(firewall([], { zones: v6_only }))[0]);
		assert.match('firewall: UDP (relayed WireGuard) from wg_hub (zone vpn): could not confirm, wg_mesh has no listen_port',
			messages(firewall(h.spoke_rules('vpn')), { ...IFACES, wg_mesh: { addresses: [ '10.20.0.11' ] } })[1]);
		assert.match('firewall: ICMPv6 echo-request (underlay probe) from zone wan: could not confirm, no such zone',
			messages(firewall([], { zones: v6_only }))[2]);

		let custom = of_firewall(spoke(), firewall([], { custom: true }));
		assert.match([ true, true, false ], map(custom, (f) => f.fix != null));
		assert.match(null, of_firewall(spoke(), firewall(h.spoke_rules('vpn')), { ...IFACES, wg_mesh: { addresses: [] } })[1].fix);
	});

	it('checks the hub\'s port on the WireGuard interface that holds serve_addr', () => {
		let hub = (rules) => of_firewall(HUB_CFG, firewall(rules));
		assert.match([ { level: 'ok', subject: 'firewall', option: 'serve_port',
			message: 'firewall: TCP port 7780 (peer list) from wg_hub (zone vpn): accepted' } ], hub([ h.hub_rule('vpn') ]));
		assert.match([ 'warn', "uci set firewall.@rule[-1].dest_port='7780'" ],
			[ hub([])[0].level, split(hub([])[0].fix.uci, '\n')[4] ]);
		assert.match([], of_firewall(HUB_CFG, firewall([]), { wg_mesh: { addresses: [ '10.20.0.1' ] } }));
	});

	it('skips the firewall when there is no /etc/config/firewall, and says nothing when it was not read', () => {
		assert.match([ { level: 'skip', subject: 'firewall', message: 'firewall: no /etc/config/firewall, not checked' } ],
			of_firewall(spoke(), { found: false }));
		assert.match([], of_firewall(spoke(), null));
	});
});

describe('check: passed and render', () => {
	it('passes unless a finding fails', () => {
		assert.match([ true, true, false ], [
			check.passed([]),
			check.passed([ { level: 'ok' }, { level: 'warn' }, { level: 'skip' } ]),
			check.passed([ { level: 'ok' }, { level: 'fail' } ]),
		]);
	});

	it('prints one line per finding, its level padded', () => {
		assert.match('ok    a\nskip  b\nwarn  c\nFAIL  d\n', check.render([
			{ level: 'ok', message: 'a' }, { level: 'skip', message: 'b' }, { level: 'warn', message: 'c' }, { level: 'fail', message: 'd' },
		]));
	});

	it('prints the rule to add under its finding, both ways', () => {
		assert.match('warn  c\n' +
			'      add it with:\n' +
			'        uci add firewall rule\n' +
			'        uci commit firewall\n' +
			'      or in /etc/config/firewall:\n' +
			'        config rule\n' +
			"        \toption name 'x'\n",
			check.render([ { level: 'warn', message: 'c', fix: { uci: 'uci add firewall rule\nuci commit firewall',
				config: "config rule\n\toption name 'x'" } } ]));
	});
});
