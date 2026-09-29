import { describe, it, assert, contains } from 'utest';
import * as fs from 'fs';
import * as uloop from 'uloop';
import * as socket from 'socket';
import * as prober from 'wgpathd.components.icmp';
import { link_mtu, random_source } from 'wgpathd.deps';

// Sends probes over the real loopback, whose kernel answers every echo, and
// collects the answers; the loop ends when all are in, or after max_ms.
function probe(probes, timeout, max_ms) {
	let answers = [];
	uloop.init();
	let guard = uloop.timer(max_ms ?? 3000, () => uloop.end());
	prober.create(socket, uloop, random_source(fs)).send(probes, timeout ?? 1, (p, res) => {
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

const FLOOD = sourcepath(0, true) + '/../fixtures/icmp_flood.uc';
const FLOOD_PID = '/tmp/wgpathd-icmp-flood.pid';

function echo_requests_received() {
	let snmp = split(fs.readfile('/proc/net/snmp'), '\n');
	let names = split(filter(snmp, (l) => index(l, 'Icmp: InMsgs') == 0)[0], ' ');
	let values = split(filter(snmp, (l) => index(l, 'Icmp: ') == 0 && index(l, 'InMsgs') < 0)[0], ' ');
	return +values[index(names, 'InEchos')];
}

// The raw socket bound to the loopback sees every echo request of the flood and every
// reply the kernel sends to it, faster than a read loop that drains it could keep up.
describe('components.icmp under a flood', () => {
	it('keeps the loop running its timers while the socket never drains', () => {
		uloop.init();
		prober.create(socket, uloop, random_source(fs)).send([ { host: '127.0.0.1', size: 16, device: 'lo' } ], 0.05, () => {});
		let before = echo_requests_received();
		system(`ucode ${FLOOD} 2 60000 & echo $! >${FLOOD_PID}`);
		let ticks = 0;
		function tick() {
			ticks++;
			uloop.timer(50, tick);
		}
		uloop.timer(250, () => {
			uloop.timer(50, tick);
			uloop.timer(1000, () => uloop.end());
		});
		uloop.run();
		system(`kill $(cat ${FLOOD_PID}) 2>/dev/null`);
		assert.match(true, echo_requests_received() - before > 1000, 'the loopback was flooded');
		assert.match(true, ticks >= 15, `a 50 ms timer fired ${ticks} times in 1 s`);
	});
});

describe('deps: random_source', () => {
	it('gives as many bytes as asked for, and others the next time', () => {
		let random = random_source(fs);
		let draws = [ random(8), random(8), random(4) ];
		assert.match([ 8, 8, 4 ], map(draws, length));
		assert.match(false, draws[0] == draws[1]);
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
