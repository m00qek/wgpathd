import { describe, it, assert } from 'utest';
import * as relay from 'wgpathd.relay';
import * as Result from 'wgpathd.result';

const PEER = { section: 'spoke_b', pubkey: 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=',
	relay: '10.10.0.12:51820', tunnel: '10.20.0.12' };

function routes(answer) {
	let asked = [];
	let route_get = function(host) {
		push(asked, host);
		return answer;
	};
	return { asked: asked, route_get: route_get };
}

describe('relay: guard', () => {
	it('manages a peer whose relay host routes out of the mesh interface', () => {
		let r = routes(Result.ok({ dst: '10.10.0.12/32', oif: 'wg_hub' }));
		assert.match({ verdict: 'managed', oif: 'wg_hub' }, relay.guard(r.route_get, 'wg_mesh', PEER));
		assert.match([ '10.10.0.12' ], r.asked, 'looks up the host, without the port');
	});

	it('rejects a relay that routes into the mesh interface', () => {
		let r = routes(Result.ok({ oif: 'wg_mesh' }));
		assert.match({ verdict: 'rejected', reason: 'relay routes into wg_mesh' },
			relay.guard(r.route_get, 'wg_mesh', PEER));
	});

	it('leaves the peer pending when the lookup fails', () => {
		let r = routes(Result.err('ROUTE_LOOKUP_FAILED', '10.10.0.12: Network unreachable'));
		assert.match({ verdict: 'pending',
			reason: 'relay route lookup failed: ROUTE_LOOKUP_FAILED (10.10.0.12: Network unreachable)' },
			relay.guard(r.route_get, 'wg_mesh', PEER));
	});

	it('looks up the bare address of an IPv6 relay', () => {
		let r = routes(Result.ok({ oif: 'wg_hub' }));
		relay.guard(r.route_get, 'wg_mesh', { ...PEER, relay: '[2001:db8::12]:51820' });
		assert.match([ '2001:db8::12' ], r.asked);
	});
});
