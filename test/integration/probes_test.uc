import { describe, it, assert, contains } from 'utest';
import * as uloop from 'uloop';
import * as socket from 'socket';
import * as prober from 'wgpathd.components.icmp';
import { link_mtu } from 'wgpathd.deps';

// Sends probes over the real loopback, whose kernel answers every echo, and
// collects the answers; the loop ends when all are in, or after max_ms.
function probe(probes, timeout, max_ms) {
	let answers = [];
	uloop.init();
	let guard = uloop.timer(max_ms ?? 3000, () => uloop.end());
	prober.create(socket, uloop, 0x5eed).send(probes, timeout ?? 1, (p, res) => {
		push(answers, [ p.host, res.ok ? res.data : res.error ]);
		if (length(answers) == length(probes))
			uloop.end();
	});
	if (length(answers) < length(probes))
		uloop.run();
	guard.cancel();
	return answers;
}

describe('components.icmp on raw sockets', () => {
	it('gets answers over IPv4 and IPv6', () => {
		let answers = probe([ { host: '127.0.0.1', size: 16, device: null }, { host: '::1', size: 16, device: null } ]);
		assert.match([ [ '127.0.0.1', true ], [ '::1', true ] ], sort(answers, (a, b) => (a[0] < b[0]) ? -1 : 1));
	});

	it('gets an answer to a large probe bound to a device', () => {
		assert.match([ [ '127.0.0.1', true ] ], probe([ { host: '127.0.0.1', size: 1400, device: 'lo' } ]));
	});

	it('fails a probe that cannot be bound to its device', () => {
		assert.match([ [ '127.0.0.1', 'PROBE_SEND_FAILED' ] ], probe([ { host: '127.0.0.1', size: 16, device: 'wgpathd-none0' } ]));
	});
});

describe('deps: link_mtu', () => {
	it('reads the MTU of an interface', () => {
		assert.match(contains({ ok: true }), link_mtu('lo'));
		assert.match(true, link_mtu('lo').data > 0);
	});

	it('fails for an interface that does not exist', () => {
		assert.match(contains({ ok: false, error: 'LINK_LOOKUP_FAILED' }), link_mtu('wgpathd-none0'));
	});
});
