import { describe, it, assert } from 'utest';
import * as address from 'wgpathd.address';

const CLASSES = {
	[address.UNSPECIFIED]:     [ '0.0.0.0', '0.1.2.3', '::' ],
	[address.LOOPBACK]:        [ '127.0.0.1', '127.255.0.9', '::1' ],
	[address.LINK_LOCAL]:      [ '169.254.1.1', 'fe80::1', 'febf:ffff::1' ],
	[address.MULTICAST]:       [ '224.0.0.1', '239.1.2.3', 'ff02::1', 'ff0e::1' ],
	[address.BROADCAST]:       [ '255.255.255.255' ],
	[address.IPV4_MAPPED]:     [ '::ffff:1.2.3.4', '::ffff:0:0' ],
	[address.IPV4_COMPATIBLE]: [ '::1.2.3.4', '::2' ],
	[address.NAT64]:           [ '64:ff9b::102:304', '64:ff9b:1::1' ],
	[address.DISCARD_ONLY]:    [ '100::', '100::ffff:ffff:ffff:ffff' ],
	[address.UNICAST]:         [ '10.10.0.1', '192.0.2.1', '2001:db8::1', 'fd00:20::12', 'fec0::1', '100:0:0:1::',
		'64:ff9b:2::1', 'fe00::1', '::1:0:0:0:1' ],
};

describe('address: kind', () => {
	it('names the special-purpose range an address lies in', () => {
		for (let k, list in CLASSES)
			for (let ip in list)
				assert.match(k, address.kind(ip), ip);
	});

	it('is null for what is not one literal address', () => {
		for (let s in [ null, 1, '', 'localhost', '10.0.0', ' 10.0.0.1', '10.0.0.1/8', '[::1]', 'fe80::1%eth0', '::1:' ])
			assert.match(null, address.kind(s), s);
	});
});

describe('address: can_listen', () => {
	it('takes an address the router can hold, loopback and IPv4 link-local included', () => {
		for (let ip in [ '10.10.0.1', '127.0.0.1', '169.254.1.1', '2001:db8::1', 'fd00::1', '::1' ])
			assert.match(true, address.can_listen(ip), ip);
	});

	it('refuses a wildcard, a group, a broadcast and an IPv6 link-local address, which needs a zone', () => {
		for (let ip in [ '0.0.0.0', '::', '224.0.0.1', 'ff02::1', '255.255.255.255', 'fe80::1', 'hub' ])
			assert.match(false, address.can_listen(ip), ip);
	});
});

describe('address: can_be_direct', () => {
	it('takes a global or a unique local IPv6 address', () => {
		for (let ip in [ '2001:db8::1', '3000::1', 'fd00:20::12', 'fc00::1' ])
			assert.match(true, address.can_be_direct(ip), ip);
	});

	it('refuses every special-purpose IPv6 range', () => {
		for (let k, list in CLASSES)
			if (k != address.UNICAST)
				for (let ip in filter(list, (ip) => index(ip, ':') >= 0))
					assert.match(false, address.can_be_direct(ip), ip);
	});

	it('refuses an IPv4 address, and what is not an address', () => {
		for (let ip in [ '10.10.0.12', '192.0.2.1', null, '', 'peer.example.org', '[2001:db8::1]:51820' ])
			assert.match(false, address.can_be_direct(ip), ip);
	});
});
