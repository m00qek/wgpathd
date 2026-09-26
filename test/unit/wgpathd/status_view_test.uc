import { describe, it, assert } from 'utest';
import * as view from 'wgpathd.status_view';

const SPOKE_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const SPOKE_A = 'ckRTxoRCqAhiHEgHPnhfpN6nU5/F2QmMe0nJ2kt7PFc=';
const HUB  = 'W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=';
const NOW  = 1790456500;

function peer(extra) {
	return { state: 'RELAY', endpoint: null, target: null, up_streak: 0, down_streak: 0, backoff: 0,
		ready: false, switches: 0, last_change: null, ...extra };
}

describe('status_view: age', () => {
	it('uses the largest whole unit', () => {
		assert.match([ '0s', '59s', '1m', '59m', '1h', '23h', '1d', '0s' ],
			map([ 0, 59, 60, 3599, 3600, 86399, 86400, -5 ], view.age));
	});
});

describe('status_view: spoke', () => {
	it('renders mode, discovery, one aligned line per peer by section, then unmanaged peers', () => {
		let status = {
			role: 'spoke', mode: 'steer', discovery: { fresh: true, last_ok: NOW - 12 },
			peers: {
				[SPOKE_B]: peer({ section: 'spoke_b', state: 'DIRECT', endpoint: '[2001:db8::12]:51820', switches: 2,
					last_change: { ts: NOW - 190, from: 'TRIALING', to: 'DIRECT', reason: 'trial_ok' } }),
				[SPOKE_A]: peer({ section: 'spoke_a', endpoint: '10.10.0.11:51820', switches: 1 }),
			},
			unmanaged: [ { section: 'hub', pubkey: HUB, reason: 'missing wgpathd_relay' } ],
		};
		assert.match(
			'role: spoke (mode steer)\n' +
			'discovery: fresh (last success 12s ago)\n' +
			'peers:\n' +
			'  spoke_a  ckRTxoRC  RELAY   10.10.0.11:51820      no change yet      1 switch\n' +
			'  spoke_b  O0LYRo/R  DIRECT  [2001:db8::12]:51820  3m ago (trial_ok)  2 switches\n' +
			'unmanaged:\n' +
			'  hub  W+1CXUTT  missing wgpathd_relay\n',
			view.render(status, NOW));
	});

	it('shows a stale discovery that never succeeded, and no peers', () => {
		let status = { role: 'spoke', mode: 'observe', discovery: { fresh: false, last_ok: null },
			peers: {}, unmanaged: [] };
		assert.match(
			'role: spoke (mode observe)\n' +
			'discovery: stale (never succeeded)\n' +
			'peers: none\n',
			view.render(status, NOW));
	});

	it('shows only unmanaged peers when none is steered', () => {
		let status = { role: 'spoke', mode: 'steer', discovery: { fresh: false, last_ok: NOW - 7200 },
			peers: {}, unmanaged: [ { section: 'spoke_b', pubkey: SPOKE_B, reason: 'relay routes into wg_mesh' } ] };
		assert.match(
			'role: spoke (mode steer)\n' +
			'discovery: stale (last success 2h ago)\n' +
			'peers: none\n' +
			'unmanaged:\n' +
			'  spoke_b  O0LYRo/R  relay routes into wg_mesh\n',
			view.render(status, NOW));
	});
});

describe('status_view: hub', () => {
	it('renders one line per published peer, by key', () => {
		let status = { role: 'hub', peers: {
			[SPOKE_B]: { direct: '[2001:db8::12]:51820', handshake_age: 9 },
			[SPOKE_A]: { direct: '[2001:db8::11]:51820' },
		} };
		assert.match(
			'role: hub\n' +
			'published peers:\n' +
			'  O0LYRo/R  [2001:db8::12]:51820  handshake 9s ago\n' +
			'  ckRTxoRC  [2001:db8::11]:51820  no handshake\n',
			view.render(status, NOW));
	});

	it('says so when nothing is published', () => {
		assert.match('role: hub\npublished peers: none\n', view.render({ role: 'hub', peers: {} }, NOW));
	});
});
