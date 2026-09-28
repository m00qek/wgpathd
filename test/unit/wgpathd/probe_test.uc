import { describe, it, prop, gen, assert } from 'utest';
import * as probe from 'wgpathd.probe';

describe('probe: underlay', () => {
	it('probes the host of a direct endpoint over IPv6 with a small payload, by the routes', () => {
		assert.match({ host: '2001:db8::a', size: 16, device: null }, probe.underlay('[2001:db8::a]:51820'));
	});

	it('probes the canonical host', () => {
		assert.match('fd42:7770:1::3', probe.underlay('[FD42:7770:1:0::3]:51820').host);
	});

	it('has no underlay probe for an IPv4 or invalid endpoint', () => {
		for (let v in [ '10.10.0.12:51820', '2001:db8::a', null, '' ])
			assert.match(null, probe.underlay(v));
	});
});

describe('probe: tunnel', () => {
	it('fills the mesh MTU with an IPv4 packet: 20 bytes of IP header and 8 of echo header', () => {
		assert.match({ host: '10.20.0.12', size: 1332, device: 'wg_mesh' }, probe.tunnel('10.20.0.12', 1360, 'wg_mesh'));
	});

	it('fills the mesh MTU with an IPv6 packet: 40 bytes of IP header and 8 of echo header', () => {
		assert.match({ host: 'fd00:2::12', size: 1372, device: 'wg_mesh' }, probe.tunnel('FD00:2:0::12', 1420, 'wg_mesh'));
	});

	prop('makes the whole packet exactly the MTU', gen.int(1280, 9000), (mtu) => {
		assert.match(mtu, probe.tunnel('10.0.0.1', mtu, 'wg0').size + 28);
		assert.match(mtu, probe.tunnel('2001:db8::1', mtu, 'wg0').size + 48);
	});

	it('never asks for a negative payload', () => {
		assert.match(0, probe.tunnel('2001:db8::1', 40, 'wg0').size);
	});

	it('has no probe for an address it cannot read', () => {
		for (let v in [ '10.20.0.300', 'wg_mesh', null ])
			assert.match(null, probe.tunnel(v, 1360, 'wg_mesh'));
	});
});
