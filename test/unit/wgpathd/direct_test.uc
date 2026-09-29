import { describe, it, assert } from 'utest';
import * as direct from 'wgpathd.direct';
import * as Result from 'wgpathd.result';

const CFG  = { mesh_iface: 'wg_mesh', hub_iface: 'wg_hub' };
const PEER = { relay: '[2001:db8:ffff::12]:51820', tunnel: 'fd00:2::12' };

// routes: host -> the route's fields, or false for a failed lookup; wan otherwise.
function route_get(routes) {
	return (host) => (routes?.[host] === false)
		? Result.err('ROUTE_LOOKUP_FAILED', `${host}: Network unreachable`)
		: Result.ok({ oif: 'wan', local: false, ...(routes?.[host] ?? {}) });
}

describe('direct: refusal', () => {
	it('takes a candidate routed out of another interface', () => {
		assert.match(null, direct.refusal(route_get(), CFG, PEER, '[2001:db8::12]:51820'));
	});

	it('refuses the peer\'s relay or tunnel address, whatever port', () => {
		assert.match('relay address', direct.refusal(route_get(), CFG, PEER, '[2001:DB8:FFFF::12]:1'));
		assert.match('tunnel address', direct.refusal(route_get(), CFG, PEER, '[fd00:2::12]:51820'));
	});

	it('refuses an address of the router itself', () => {
		let routes = { '2001:db8::1': { oif: 'lo', local: true } };
		assert.match('own address', direct.refusal(route_get(routes), CFG, PEER, '[2001:db8::1]:51820'));
	});

	it('refuses a candidate routed into the mesh or the hub tunnel', () => {
		let routes = { 'fd00:20::1': { oif: 'wg_mesh' }, 'fd00:30::1': { oif: 'wg_hub' } };
		assert.match('routes into wg_mesh', direct.refusal(route_get(routes), CFG, PEER, '[fd00:20::1]:51820'));
		assert.match('routes into wg_hub', direct.refusal(route_get(routes), CFG, PEER, '[fd00:30::1]:51820'));
	});

	it('refuses nothing for want of a route', () => {
		assert.match(null, direct.refusal(route_get({ '2001:db8::12': false }), CFG, PEER, '[2001:db8::12]:51820'));
	});
});
