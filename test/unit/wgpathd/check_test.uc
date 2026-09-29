import { describe, it, assert } from 'utest';
import * as check from 'wgpathd.check';
import * as Result from 'wgpathd.result';
import * as relay from 'wgpathd.relay';
import * as h from 'lib.helpers';

const SPOKE_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const HUB  = 'W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=';

const SPOKE_B_PEER = { section: 'spoke_b', pubkey: SPOKE_B, relay: '10.10.0.12:51820', tunnel: '10.20.0.12' };

function spoke(unmanaged) {
	return Result.ok({ role: 'spoke', mesh_iface: 'wg_mesh', hub_iface: 'wg_hub', mode: 'steer', overrides: {},
		peers: { managed: [ SPOKE_B_PEER ], unmanaged: unmanaged ?? [] } });
}

const HUB_CFG = Result.ok({ role: 'hub', read_iface: 'wg_mesh', serve_addr: '192.0.2.1', serve_port: '7780', overrides: {} });

const WG_UP = Result.ok({ ...h.status_reply('wg_mesh', { [SPOKE_B]: { hs: 0 } }), ...h.status_reply('wg_hub', {}) });

function obs(extra) {
	return { enabled: null, wireguard: null, routes: { spoke_b: { verdict: relay.MANAGED, oif: 'wg_hub' } }, ...(extra ?? {}) };
}

describe('check: findings for the config alone', () => {
	it('names the option a loader error is about', () => {
		let cases = [
			[ Result.err('CONFIG_INVALID_ROLE', 'unset'), { option: 'role' }, "option role must be 'spoke' or 'hub' (is unset)" ],
			[ Result.err('CONFIG_MISSING_OPTION', 'discovery'), { option: 'discovery' }, 'missing option discovery' ],
			[ Result.err('CONFIG_INVALID_OPTION', 'cycle'), { option: 'cycle' }, 'option cycle must be a positive number' ],
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
});

describe('check: findings for the peers', () => {
	it('marks every peer finding with its section, and a bad annotation with its option', () => {
		let loaded = spoke([
			{ section: 'hub', pubkey: HUB, reason: 'missing wgpathd_relay' },
			{ section: 'spoke_c', pubkey: null, reason: 'invalid public_key' },
		]);
		assert.match([
			{ level: 'ok', subject: 'peer', section: 'spoke_b',
				message: 'peer spoke_b: relay 10.10.0.12:51820 via wg_hub, probes 10.20.0.12' },
			{ level: 'skip', subject: 'peer', section: 'hub', option: 'wgpathd_relay',
				message: 'peer hub: not steered (missing wgpathd_relay)' },
			{ level: 'fail', subject: 'peer', section: 'spoke_c', option: 'public_key',
				message: 'peer spoke_c: not steered (invalid public_key)' },
		], slice(check.findings(loaded, obs()), 1));
	});

	it('marks a relay routed into the mesh on wgpathd_relay, and a pending lookup on no option', () => {
		let rejected = check.findings(spoke(), obs({ routes: { spoke_b: { verdict: relay.REJECTED, reason: 'relay routes into wg_mesh' } } }));
		assert.match({ level: 'fail', subject: 'peer', section: 'spoke_b', option: 'wgpathd_relay',
			message: 'peer spoke_b: relay routes into wg_mesh' }, rejected[1]);
		let pending = check.findings(spoke(), obs({ routes: { spoke_b: { verdict: relay.PENDING, reason: 'relay route lookup failed: X' } } }));
		assert.match({ level: 'warn', subject: 'peer', section: 'spoke_b',
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
});
