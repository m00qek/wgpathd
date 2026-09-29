import { describe, it, assert, contains } from 'utest';
import * as icmp from 'wgpathd.icmp';
import * as prober from 'wgpathd.components.icmp';

const IP4_HEADER = '\x45\x00\x00\x00\x00\x00\x40\x00\x40\x01\x00\x00\x0a\x00\x00\x02\x0a\x00\x00\x01';

// A socket module whose sockets record what is sent and hand out queued datagrams.
function fake_socket() {
	let s = { AF_INET: 2, AF_INET6: 10, SOCK_RAW: 3, SOCK_NONBLOCK: 2048, SOL_SOCKET: 1, SO_BINDTODEVICE: 25,
		IPPROTO_IP: 0, IPPROTO_IPV6: 41, IP_MTU_DISCOVER: 10, IPV6_DONTFRAG: 62,
		opened: [], last_error: null, refuse_create: false, refuse_opt: null, refuse_send: null };
	let fail = function(msg) {
		s.last_error = msg;
		return null;
	};
	s.error = () => s.last_error;
	s.create = function(family, socktype, protocol) {
		if (s.refuse_create)
			return fail('socket(): Operation not permitted');
		let sock = { family: family, socktype: socktype, protocol: protocol, opts: [], sent: [], inbox: [], closed: false };
		sock.setopt = (level, opt, value) => (opt == s.refuse_opt)
			? fail('setsockopt(): No such device')
			: (push(sock.opts, [ level, opt, value ]) && true);
		sock.send = function(data, flags, addr) {
			if (s.refuse_send)
				return fail(s.refuse_send);
			push(sock.sent, { data: data, addr: addr });
			return length(data);
		};
		sock.recvmsg = (size) => shift(sock.inbox);
		sock.close = function() { sock.closed = true; };
		push(s.opened, sock);
		return sock;
	};
	return s;
}

function fake_uloop() {
	let l = { ULOOP_READ: 1, handles: [], timers: [] };
	l.handle = function(sock, cb, flags) {
		push(l.handles, { sock: sock, cb: cb, flags: flags });
		return { delete: () => true };
	};
	l.timer = function(ms, cb) {
		push(l.timers, { ms: ms, cb: cb });
		return { cancel: () => true };
	};
	return l;
}

// Random bytes that differ from draw to draw and are the same in every run; a test
// may queue the bytes of the next draws, or make every draw fail.
function fake_random() {
	let r = { draws: 0, queued: [], fails: false };
	r.bytes = function(n) {
		if (r.fails)
			return null;
		if (length(r.queued) > 0)
			return shift(r.queued);
		r.draws++;
		return join('', map(slice([ 0, 1, 2, 3, 4, 5, 6, 7 ], 0, n), (i) => chr((r.draws * 31 + i * 7) & 0xff)));
	};
	return r;
}

function setup() {
	let t = { socket: fake_socket(), uloop: fake_uloop(), random: fake_random(), results: [] };
	t.prober = prober.create(t.socket, t.uloop, t.random.bytes);
	t.send = (probes, timeout) => t.prober.send(probes, timeout ?? 1, (p, res) => push(t.results, [ p.host, res ]));
	t.answers = () => map(t.results, (r) => [ r[0], r[1].ok ? r[1].data : r[1].error ]);
	t.wakeup = (sock) => filter(t.uloop.handles, (h) => h.sock == sock)[0].cb();
	t.queue = function(sock, ...datagrams) {
		for (let d in datagrams)
			push(sock.inbox, { data: d[0], address: { address: d[1] } });
	};
	// Queues datagrams on a socket, then lets the loop see it readable once.
	t.deliver = function(sock, ...datagrams) {
		t.queue(sock, ...datagrams);
		t.wakeup(sock);
	};
	return t;
}

function u16(n) {
	return chr((n >> 8) & 0xff, n & 0xff);
}

function field(data, at) {
	return (ord(data, at) << 8) | ord(data, at + 1);
}

// The reply a peer's kernel sends to a request, or a variation of it.
function reply(fam, request, changes) {
	changes ??= {};
	let id = changes.id ?? field(request, 4);
	let seq = changes.seq ?? field(request, 6);
	let data = changes.payload ?? substr(request, 8);
	let type = changes.type ?? ((fam == 4) ? 0 : 129);
	let msg = chr(type, 0) + u16(0) + u16(id) + u16(seq) + data;
	msg = chr(type, 0) + u16(icmp.checksum(msg)) + u16(id) + u16(seq) + data;
	return (fam == 4) ? IP4_HEADER + msg : msg;
}

describe('components.icmp: sockets', () => {
	it('opens one raw socket per family and device, when first needed, and reuses it', () => {
		let t = setup();
		assert.match([], t.socket.opened);
		t.send([ { host: '10.0.0.2', size: 8, device: 'wg_mesh' }, { host: '10.0.0.3', size: 8, device: 'wg_mesh' },
			{ host: '2001:db8::2', size: 8, device: null }, { host: 'fd00::2', size: 8, device: 'wg_mesh' } ]);
		t.send([ { host: '10.0.0.2', size: 8, device: 'wg_mesh' }, { host: '2001:db8::3', size: 8, device: null } ]);
		assert.match([ [ 2, 3 | 2048, 1 ], [ 10, 3 | 2048, 58 ], [ 10, 3 | 2048, 58 ] ],
			map(t.socket.opened, (s) => [ s.family, s.socktype, s.protocol ]));
		assert.match([ 3, 2, 1 ], map(t.socket.opened, (s) => length(s.sent)));
		assert.match(3, length(t.uloop.handles));
		assert.match([ 1, 1, 1 ], map(t.uloop.handles, (h) => h.flags));
	});

	it('forbids local fragmentation and binds to the device', () => {
		let t = setup();
		t.send([ { host: '10.0.0.2', size: 8, device: 'wg_mesh' }, { host: '2001:db8::2', size: 8, device: null },
			{ host: 'fd00::2', size: 8, device: 'wg_mesh' } ]);
		assert.match([
			[ [ 0, 10, 2 ], [ 1, 25, 'wg_mesh' ] ],
			[ [ 41, 62, 1 ] ],
			[ [ 41, 62, 1 ], [ 1, 25, 'wg_mesh' ] ],
		], map(t.socket.opened, (s) => s.opts));
	});

	it('binds again by name for every probe, so a device created anew is used', () => {
		let t = setup();
		t.send([ { host: '10.0.0.2', size: 8, device: 'wg_mesh' }, { host: '10.0.0.3', size: 8, device: 'wg_mesh' } ]);
		t.send([ { host: '10.0.0.2', size: 8, device: 'wg_mesh' } ]);
		assert.match(3, length(filter(t.socket.opened[0].opts, (o) => o[1] == 25)));
	});

	it('sends an echo request with the id and the next sequence number of its socket, and the payload size asked for', () => {
		let t = setup();
		push(t.random.queued, '\x12\x34\x00\x07');
		t.send([ { host: '10.0.0.2', size: 1332, device: 'wg_mesh' }, { host: '10.0.0.3', size: 0, device: 'wg_mesh' } ]);
		t.send([ { host: '10.0.0.2', size: 1332, device: 'wg_mesh' } ]);
		let sent = t.socket.opened[0].sent;
		assert.match([ [ 8, 0x1234, 8, 1340 ], [ 8, 0x1234, 9, 8 ], [ 8, 0x1234, 10, 1340 ] ],
			map(sent, (s) => [ ord(s.data, 0), field(s.data, 4), field(s.data, 6), length(s.data) ]));
		assert.match({ family: 2, address: '10.0.0.2', port: 0 }, sent[0].addr);
		assert.match([ 0, 0, 0 ], map(sent, (s) => icmp.checksum(s.data)), 'each carries a checksum that adds up');
	});

	it('starts the sequence numbers over after 65535', () => {
		let t = setup();
		push(t.random.queued, '\x12\x34\xff\xfe');
		t.send([ { host: '10.0.0.2', size: 16, device: 'wg_mesh' }, { host: '10.0.0.2', size: 16, device: 'wg_mesh' } ]);
		assert.match([ 0xffff, 0 ], map(t.socket.opened[0].sent, (s) => field(s.data, 6)));
	});

	it('draws an id and a first sequence number for each socket', () => {
		let t = setup();
		push(t.random.queued, '\x12\x34\x00\x07', 'nonce 01', '\xab\xcd\x90\x00', 'nonce 02');
		t.send([ { host: '2001:db8::2', size: 16, device: null }, { host: 'fd00::2', size: 16, device: 'wg_mesh' } ]);
		assert.match([ [ 0x1234, 8 ], [ 0xabcd, 0x9001 ] ],
			map(t.socket.opened, (s) => [ field(s.sent[0].data, 4), field(s.sent[0].data, 6) ]));
	});

	it('gives every probe a nonce of its own, before the same filler', () => {
		let t = setup();
		push(t.random.queued, '\x12\x34\x00\x07', 'nonce 01', 'nonce 02');
		t.send([ { host: '10.0.0.2', size: 1332, device: 'wg_mesh' }, { host: '10.0.0.3', size: 1332, device: 'wg_mesh' } ]);
		let payloads = map(t.socket.opened[0].sent, (s) => substr(s.data, 8));
		assert.match([ 'nonce 01' + icmp.filler(1324), 'nonce 02' + icmp.filler(1324) ], payloads);
	});
});

describe('components.icmp: answers', () => {
	it('answers a probe as soon as its reply arrives', () => {
		let t = setup();
		t.send([ { host: '10.0.0.2', size: 16, device: 'wg_mesh' } ]);
		let sock = t.socket.opened[0];
		t.deliver(sock, [ reply(4, sock.sent[0].data), '10.0.0.2' ]);
		assert.match([ [ '10.0.0.2', true ] ], t.answers());
		t.uloop.timers[0].cb();
		assert.match([ [ '10.0.0.2', true ] ], t.answers(), 'answered once');
	});

	it('gives up on every unanswered probe of a batch at its timeout, to the millisecond', () => {
		let t = setup();
		t.send([ { host: '2001:db8::2', size: 16, device: null }, { host: '2001:db8::3', size: 16, device: null } ], 0.35);
		let sock = t.socket.opened[0];
		t.deliver(sock, [ reply(6, sock.sent[1].data), '2001:db8::3' ]);
		assert.match([ 350 ], map(t.uloop.timers, (x) => x.ms));
		t.uloop.timers[0].cb();
		assert.match([ [ '2001:db8::3', true ], [ '2001:db8::2', false ] ], t.answers());
	});

	it('reads every datagram waiting when the socket turns readable', () => {
		let t = setup();
		t.send([ { host: '10.0.0.2', size: 16, device: 'wg_mesh' }, { host: '10.0.0.3', size: 16, device: 'wg_mesh' } ]);
		let sock = t.socket.opened[0];
		t.deliver(sock, [ reply(4, sock.sent[0].data), '10.0.0.2' ], [ reply(4, sock.sent[1].data), '10.0.0.3' ]);
		assert.match([ [ '10.0.0.2', true ], [ '10.0.0.3', true ] ], t.answers());
	});

	it('matches a probe whose host is written another way', () => {
		let t = setup();
		t.send([ { host: '2001:DB8:0::2', size: 16, device: null } ]);
		let sock = t.socket.opened[0];
		t.deliver(sock, [ reply(6, sock.sent[0].data), '2001:db8::2' ]);
		assert.match([ [ '2001:DB8:0::2', true ] ], t.answers());
	});

	it('matches a reply whose source is written another way', () => {
		let t = setup();
		t.send([ { host: '2001:db8::2', size: 16, device: null } ]);
		let sock = t.socket.opened[0];
		t.deliver(sock, [ reply(6, sock.sent[0].data), '2001:DB8:0:0::2' ]);
		assert.match([ [ '2001:db8::2', true ] ], t.answers());
	});

	it('reads at most 32 datagrams per wakeup, and the rest when the loop comes back', () => {
		let t = setup();
		t.send([ { host: '10.0.0.2', size: 16, device: 'wg_mesh' } ]);
		let sock = t.socket.opened[0];
		let req = sock.sent[0].data;
		for (let i = 0; i < 32; i++)
			t.queue(sock, [ IP4_HEADER + req, '10.0.0.9' ]);
		t.queue(sock, [ reply(4, req), '10.0.0.2' ]);
		t.wakeup(sock);
		assert.match([], t.answers());
		assert.match(1, length(sock.inbox), 'the reply is left for the next wakeup');
		t.wakeup(sock);
		assert.match([ [ '10.0.0.2', true ] ], t.answers());
	});

	it('ignores whatever does not answer the probe, and still takes the reply that does', () => {
		let t = setup();
		t.send([ { host: '10.0.0.2', size: 16, device: 'wg_mesh' } ]);
		let sock = t.socket.opened[0];
		let req = sock.sent[0].data;
		let others = {
			'another id': [ reply(4, req, { id: field(req, 4) ^ 1 }), '10.0.0.2' ],
			'another sequence': [ reply(4, req, { seq: field(req, 6) + 1 }), '10.0.0.2' ],
			'another source': [ reply(4, req), '10.0.0.9' ],
			'an echo request': [ IP4_HEADER + req, '10.0.0.2' ],
			'a destination unreachable': [ reply(4, req, { type: 3 }), '10.0.0.2' ],
			'a truncated packet': [ substr(reply(4, req), 0, 25), '10.0.0.2' ],
			'a shortened payload': [ reply(4, req, { payload: substr(req, 8, 10) }), '10.0.0.2' ],
			'a longer payload': [ reply(4, req, { payload: substr(req, 8) + 'x' }), '10.0.0.2' ],
			'another nonce': [ reply(4, req, { payload: 'guessed!' + substr(req, 16) }), '10.0.0.2' ],
			'the filler alone': [ reply(4, req, { payload: icmp.filler(16) }), '10.0.0.2' ],
			'another filler': [ reply(4, req, { payload: substr(req, 8, 8) + 'WGPATHD ' }), '10.0.0.2' ],
			'a corrupted packet': [ substr(reply(4, req), 0, 30) + 'X' + substr(reply(4, req), 31), '10.0.0.2' ],
		};
		for (let what, d in others) {
			t.deliver(sock, d);
			assert.match([], t.answers(), what);
		}
		t.deliver(sock, [ reply(4, req), '10.0.0.2' ]);
		assert.match([ [ '10.0.0.2', true ] ], t.answers());
	});

	it('ignores a reply that comes after its probe gave up, even when the host is probed again', () => {
		let t = setup();
		t.send([ { host: '10.0.0.2', size: 16, device: 'wg_mesh' } ]);
		let sock = t.socket.opened[0];
		let stale = reply(4, sock.sent[0].data);
		t.uloop.timers[0].cb();
		t.deliver(sock, [ stale, '10.0.0.2' ]);
		assert.match([ [ '10.0.0.2', false ] ], t.answers());

		t.send([ { host: '10.0.0.2', size: 16, device: 'wg_mesh' } ]);
		t.deliver(sock, [ stale, '10.0.0.2' ]);
		assert.match([ [ '10.0.0.2', false ] ], t.answers(), 'the old reply does not answer the new probe');
		t.deliver(sock, [ reply(4, sock.sent[1].data), '10.0.0.2' ]);
		assert.match([ [ '10.0.0.2', false ], [ '10.0.0.2', true ] ], t.answers());
	});
});

// The attack of the 2026-09-29 audit: the underlay probes show an id and sequence
// numbers in the clear, and a reply forged with the peer's tunnel address as its source
// reaches the unbound ICMPv6 socket from the WAN.
describe('components.icmp: forged replies', () => {
	const UNDERLAY = { host: '2001:db8:bad::1', size: 16, device: null };
	const TUNNEL   = { host: 'fd00:20::12', size: 1372, device: 'wg_mesh' };

	it('ignores the reply to a tunnel probe that arrives on another socket', () => {
		let t = setup();
		t.send([ UNDERLAY ]);
		t.send([ TUNNEL ]);
		let unbound = t.socket.opened[0], bound = t.socket.opened[1];
		let perfect = reply(6, bound.sent[0].data);
		t.deliver(unbound, [ perfect, 'fd00:20::12' ]);
		assert.match([], t.answers());
		t.deliver(bound, [ perfect, 'fd00:20::12' ]);
		assert.match([ [ 'fd00:20::12', true ] ], t.answers());
	});

	it('ignores a reply built from what the underlay probe showed', () => {
		let t = setup();
		t.send([ UNDERLAY ]);
		t.send([ TUNNEL ]);
		let unbound = t.socket.opened[0], bound = t.socket.opened[1];
		let seen = unbound.sent[0].data;
		let forged = [];
		for (let seq = field(seen, 6) - 2; seq <= field(seen, 6) + 2; seq++)
			for (let nonce in [ substr(seen, 8, 8), 'wgpathd ' ])
				push(forged, [ reply(6, seen, { seq: seq, payload: nonce + icmp.filler(1364) }), 'fd00:20::12' ]);
		t.deliver(unbound, ...forged);
		t.deliver(bound, ...forged);
		assert.match([], t.answers());
	});

	it('ignores a reply with the right source, id and sequence number but another nonce', () => {
		let t = setup();
		t.send([ TUNNEL ]);
		let bound = t.socket.opened[0];
		let req = bound.sent[0].data;
		t.deliver(bound, [ reply(6, req, { payload: '\x00\x00\x00\x00\x00\x00\x00\x00' + substr(req, 16) }), 'fd00:20::12' ]);
		assert.match([], t.answers());
		t.uloop.timers[0].cb();
		assert.match([ [ 'fd00:20::12', false ] ], t.answers());
	});

	it('gives up on a probe at its timeout on the socket it left by', () => {
		let t = setup();
		t.send([ UNDERLAY, TUNNEL ]);
		t.deliver(t.socket.opened[0], [ reply(6, t.socket.opened[0].sent[0].data), '2001:db8:bad::1' ]);
		t.uloop.timers[0].cb();
		assert.match([ [ '2001:db8:bad::1', true ], [ 'fd00:20::12', false ] ], t.answers());
	});
});

describe('components.icmp: failures', () => {
	it('fails a probe without random bytes, and opens no socket for it', () => {
		let t = setup();
		t.random.fails = true;
		t.send([ { host: '10.0.0.2', size: 16, device: 'wg_mesh' } ]);
		assert.match([ [ '10.0.0.2', 'PROBE_SEND_FAILED' ] ], t.answers());
		assert.match('no random bytes', t.results[0][1].details);
		assert.match([], t.socket.opened);
		assert.match([], t.uloop.timers);
	});

	it('fails a probe whose nonce comes short, and sends the next one', () => {
		let t = setup();
		push(t.random.queued, '\x12\x34\x00\x07', 'short');
		t.send([ { host: '10.0.0.2', size: 16, device: 'wg_mesh' } ]);
		assert.match([ [ '10.0.0.2', 'PROBE_SEND_FAILED' ] ], t.answers());
		t.send([ { host: '10.0.0.2', size: 16, device: 'wg_mesh' } ]);
		assert.match([ 1 ], map(t.socket.opened, (s) => length(s.sent)));
	});

	it('fails a probe at once when the kernel refuses to send it, and waits for the others', () => {
		let t = setup();
		t.send([ { host: '10.0.0.2', size: 16, device: 'wg_mesh' } ]);
		t.socket.refuse_send = 'send(): Message too large';
		t.send([ { host: '10.0.0.3', size: 1400, device: 'wg_mesh' } ]);
		assert.match([ [ '10.0.0.3', 'PROBE_SEND_FAILED' ] ], t.answers());
		assert.match(contains({ details: '10.0.0.3: send(): Message too large' }), t.results[0][1]);
		assert.match(1, length(t.uloop.timers), 'no timer for a batch with nothing sent');
	});

	it('fails every probe when no raw socket can be opened', () => {
		let t = setup();
		t.socket.refuse_create = true;
		t.send([ { host: '10.0.0.2', size: 16, device: 'wg_mesh' }, { host: '2001:db8::2', size: 16, device: null } ]);
		assert.match([ [ '10.0.0.2', 'PROBE_SEND_FAILED' ], [ '2001:db8::2', 'PROBE_SEND_FAILED' ] ], t.answers());
		assert.match('raw socket: socket(): Operation not permitted', t.results[0][1].details);
		assert.match([], t.uloop.timers);
	});

	it('fails a probe while its device is missing, and sends the next one once it is back', () => {
		let t = setup();
		t.socket.refuse_opt = 25;
		t.send([ { host: '10.0.0.2', size: 16, device: 'wg_mesh' } ]);
		assert.match('raw socket on wg_mesh: setsockopt(): No such device', t.results[0][1].details);
		t.socket.refuse_opt = null;
		t.send([ { host: '10.0.0.2', size: 16, device: 'wg_mesh' } ]);
		assert.match([ 1 ], map(t.socket.opened, (s) => length(s.sent)), 'the same socket');
	});

	it('closes a socket it cannot configure, and tries a new one for the next probe', () => {
		let t = setup();
		t.socket.refuse_opt = 10;
		t.send([ { host: '10.0.0.2', size: 16, device: null } ]);
		assert.match('raw socket: setsockopt(): No such device', t.results[0][1].details);
		assert.match(true, t.socket.opened[0].closed);
		assert.match([], t.uloop.handles);
		t.socket.refuse_opt = null;
		t.send([ { host: '10.0.0.2', size: 16, device: null } ]);
		assert.match([ 0, 1 ], map(t.socket.opened, (s) => length(s.sent)));
	});

	it('fails a probe to something that is not an IP address', () => {
		let t = setup();
		t.send([ { host: 'wg_mesh', size: 16, device: null } ]);
		assert.match([ [ 'wg_mesh', 'PROBE_SEND_FAILED' ] ], t.answers());
		assert.match([], t.socket.opened);
	});
});
