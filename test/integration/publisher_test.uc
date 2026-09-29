import { describe, it, assert, contains } from 'utest';
import { readfile } from 'fs';
import * as uloop from 'uloop';
import * as uclient from 'uclient';
import * as socket from 'socket';
import * as publisher from 'wgpathd.publisher';
import * as discovery from 'wgpathd.discovery';
import * as http from 'wgpathd.components.http';
import * as wg from 'wgpathd.wg';

const STATUS = json(readfile(sourcepath(0, true) + '/../fixtures/wireguard_status.json'));
const PEER_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const PEER_C = 'ckRTxoRCqAhiHEgHPnhfpN6nU5/F2QmMe0nJ2kt7PFc=';
const WALL   = 1790456500;
const PORT   = 17780;

const SNAPSHOT = { [PEER_B]: { direct: '[fd42:7770:1::3]:51820', handshake_age: 9 } };

function headers(status, text, body) {
	return `HTTP/1.0 ${status} ${text}\r\nContent-Type: application/json\r\nContent-Length: ${length(body)}\r\n` +
		`Connection: close\r\n\r\n${body}`;
}

describe('publisher: snapshot', () => {
	it('publishes only v6 endpoints, with the wall-clock handshake age', () => {
		let peers = wg.parse_status(STATUS, 'wg_mesh').data;
		assert.match(SNAPSHOT, publisher.snapshot(peers, WALL));
	});

	it('publishes no endpoint a spoke could not take as a direct path', () => {
		let peers = {};
		for (let a in [ '::1', 'fe80::1', '::ffff:1.2.3.4', '64:ff9b::102:304', 'ff02::1' ])
			peers[sprintf('%043d=', length(peers))] = { endpoint: `[${a}]:51820`, last_hs_ts: null };
		peers[PEER_C] = { endpoint: '[fd00:20::13]:51820', last_hs_ts: null };
		assert.match({ [PEER_C]: { direct: '[fd00:20::13]:51820' } }, publisher.snapshot(peers, WALL));
	});

	it('omits the age of a peer that never completed a handshake', () => {
		let peers = { [PEER_C]: { endpoint: '[2001:db8::1]:51820', last_hs_ts: null } };
		assert.match({ [PEER_C]: { direct: '[2001:db8::1]:51820' } }, publisher.snapshot(peers, WALL));
	});

	it('never reports a negative age when the clock is behind the handshake', () => {
		let peers = { [PEER_C]: { endpoint: '[2001:db8::1]:51820', last_hs_ts: WALL + 5 } };
		assert.match(0, publisher.snapshot(peers, WALL)[PEER_C].handshake_age);
	});

	it('is a payload spokes accept', () => {
		let peers = wg.parse_status(STATUS, 'wg_mesh').data;
		assert.match(contains({ ok: true, data: SNAPSHOT }), discovery.parse(sprintf('%J', publisher.snapshot(peers, WALL))));
	});
});

describe('publisher: respond', () => {
	it('serves the snapshot on GET /peers', () => {
		let body = sprintf('%J', SNAPSHOT);
		assert.match(headers(200, 'OK', body), publisher.respond('GET /peers HTTP/1.0\r\nHost: x\r\n\r\n', SNAPSHOT));
		assert.match(headers(200, 'OK', body), publisher.respond('GET /peers HTTP/1.1\n\n', SNAPSHOT));
	});

	it('answers 404 for any other path', () => {
		for (let path in [ '/', '/peers/', '/peers?x=1', '/status' ])
			assert.match(headers(404, 'Not Found', '{ "error": "not found" }'),
				publisher.respond(`GET ${path} HTTP/1.0\r\n\r\n`, SNAPSHOT), path);
	});

	it('answers 405 for any other method', () => {
		for (let method in [ 'POST', 'HEAD', 'PUT' ])
			assert.match(headers(405, 'Method Not Allowed', '{ "error": "method not allowed" }'),
				publisher.respond(`${method} /peers HTTP/1.0\r\n\r\n`, SNAPSHOT), method);
	});

	it('answers 400 for an unparseable request', () => {
		for (let req in [ '', 'garbage\r\n\r\n', 'GET /peers\r\n\r\n', 'get /peers HTTP/1.0\r\n\r\n',
			'GET /peers HTTP/2.0\r\n\r\n', 'GET  /peers HTTP/1.0\r\n\r\n' ])
			assert.match(headers(400, 'Bad Request', '{ "error": "bad request" }'), publisher.respond(req, SNAPSHOT), req);
	});
});

describe('publisher: listen on a real socket', () => {
	function on_loop(fn) {
		uloop.init();
		let guard = uloop.timer(3000, () => uloop.end());
		fn();
		uloop.run();
		guard.cancel();
	}

	it('serves GET /peers over TCP on loopback', () => {
		let answers = [];
		on_loop(() => {
			let deps = { socket: socket, uloop: uloop };
			let server = publisher.listen(deps, '127.0.0.1', PORT, () => SNAPSHOT).data;
			let client = http.create(uclient, uloop);
			client.get(`http://127.0.0.1:${PORT}/peers`, 1000, 65536, (res) => {
				push(answers, res);
				client.get(`http://127.0.0.1:${PORT}/other`, 1000, 65536, (res) => {
					push(answers, res);
					server.close();
					uloop.end();
				});
			});
		});
		assert.match([
			contains({ ok: true, data: { status: 200, body: sprintf('%J', SNAPSHOT) } }),
			contains({ ok: true, data: { status: 404 } }),
		], answers);
	});

	it('refuses an address it cannot bind', () => {
		let res = publisher.listen({ socket: socket, uloop: uloop }, '192.0.2.1', PORT, () => ({}));
		assert.match(contains({ ok: false, error: 'PUBLISHER_LISTEN_FAILED' }), res);
	});
});

// A socket module whose server accepts the connections a test queues, from the source
// it names, and a loop that runs what the test fires.
function fake_server() {
	let t = { queue: [], conns: [], handles: [], timers: [] };
	t.socket = {
		SOCK_STREAM: 1, MSG_DONTWAIT: 64, MSG_NOSIGNAL: 16384,
		error: () => 'fake',
		listen: () => ({
			accept: function(peer) {
				let c = shift(t.queue);
				if (c == null)
					return null;
				peer.address = c.source;
				return c;
			},
			close: () => true,
		}),
	};
	t.uloop = {
		ULOOP_READ: 1,
		handle: function(sock, cb) {
			let h = { sock: sock, cb: cb, live: true };
			h.delete = () => { h.live = false; };
			push(t.handles, h);
			return h;
		},
		timer: function(ms, cb) {
			let tm = { ms: ms, cb: cb, live: true };
			tm.cancel = () => { tm.live = false; };
			push(t.timers, tm);
			return tm;
		},
	};
	t.server = publisher.listen({ socket: t.socket, uloop: t.uloop }, '10.10.0.1', 7780, () => SNAPSHOT).data;
	t.connect = function(source, n) {
		let made = [];
		for (let i = 0; i < (n ?? 1); i++) {
			let c = { source: source, id: length(t.conns), inbox: [], sent: [], closed: false };
			c.recv = () => shift(c.inbox);
			c.send = (data) => { push(c.sent, data); return length(data); };
			c.close = () => { c.closed = true; };
			push(t.conns, c);
			push(t.queue, c);
			push(made, c);
			t.handles[0].cb();
		}
		return made;
	};
	t.handle_of = (c) => filter(t.handles, (h) => h.sock == c)[0];
	t.timer_of = (c) => t.timers[index(t.handles, t.handle_of(c)) - 1];
	t.say = function(c, data) {
		push(c.inbox, data);
		t.handle_of(c).cb();
	};
	t.open_ids = () => map(filter(t.conns, (c) => !c.closed), (c) => c.id);
	return t;
}

describe('publisher: connection limits', () => {
	it('holds at most two connections per source, closing its oldest for a new one', () => {
		let t = fake_server();
		t.connect('10.10.0.12', 3);
		assert.match([ 1, 2 ], t.open_ids());
		t.connect('10.10.0.12', 2);
		assert.match([ 3, 4 ], t.open_ids());
		assert.match(2, t.server.connections());
	});

	it('compares sources in their canonical form', () => {
		let t = fake_server();
		t.connect('fd00::12');
		t.connect('FD00:0::12');
		t.connect('fd00:0:0::12');
		assert.match([ 1, 2 ], t.open_ids());
	});

	it('takes a new source when full, in place of the oldest connection still waiting', () => {
		let t = fake_server();
		for (let i = 1; i <= 8; i++)
			t.connect(`10.10.0.${i}`, 2);
		assert.match(16, t.server.connections());
		let late = t.connect('10.10.0.99')[0];
		assert.match([ true, false, 16 ], [ t.conns[0].closed, late.closed, t.server.connections() ]);
		t.say(late, 'GET /peers HTTP/1.0\r\n\r\n');
		assert.match(true, index(late.sent[0], 'HTTP/1.0 200 OK') == 0);
	});

	it('answers a client of another source however one source churns', () => {
		let t = fake_server();
		let answered = 0;
		for (let round = 0; round < 12; round++) {
			t.connect('10.10.0.66', 16);
			let c = t.connect('10.10.0.12')[0];
			t.connect('10.10.0.66', 16);
			t.say(c, 'GET /peers HTTP/1.0\r\n\r\n');
			if (index(c.sent[0] ?? '', '200 OK') > 0)
				answered++;
		}
		assert.match(12, answered);
	});

	it('counts every way a connection ends, once, down to zero', () => {
		let t = fake_server();
		let c = t.connect('10.10.0.1', 1);
		c = [ ...c, ...t.connect('10.10.0.2', 1), ...t.connect('10.10.0.3', 1), ...t.connect('10.10.0.4', 2) ];
		assert.match(5, t.server.connections());
		t.say(c[0], 'GET /peers HTTP/1.0\r\n\r\n');                 // answered
		t.say(c[1], null);                                           // gone, or an error
		t.timer_of(c[2]).cb();                                       // timed out
		t.say(c[3], sprintf('%4097s', 'x'));                        // too large
		assert.match(1, t.server.connections());
		t.timer_of(c[0]).cb();
		t.timer_of(c[2]).cb();
		t.say(c[1], null);
		assert.match(1, t.server.connections(), 'a second end of the same connection counts for nothing');
		t.server.close();
		assert.match([ 0, [] ], [ t.server.connections(), t.open_ids() ]);
	});
});

describe('publisher: one source holding connections on a real socket', () => {
	const ATTACKER = '127.0.0.2';

	function connect_from(source) {
		let s = socket.create(socket.AF_INET, socket.SOCK_STREAM);
		s.bind({ address: source, port: 0 });
		s.connect({ address: '127.0.0.1', port: PORT });
		return s;
	}

	// The audit's `slow` and `churn`: 16 connections held open without a request,
	// opened again every 100 ms, while a client from 127.0.0.1 fetches 12 times.
	it('never keeps a client of another source from its answer', () => {
		let answers = [];
		let server;
		uloop.init();
		let guard = uloop.timer(8000, () => uloop.end());
		server = publisher.listen({ socket: socket, uloop: uloop }, '127.0.0.1', PORT, () => SNAPSHOT).data;
		let held = [];
		let churn = function() {
			for (let s in held)
				s.close();
			held = map([ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 ], () => connect_from(ATTACKER));
		};
		let churning = uloop.interval(100, churn);
		churn();
		let client = http.create(uclient, uloop);
		function fetch() {
			client.get(`http://127.0.0.1:${PORT}/peers`, 1000, 65536, (res) => {
				push(answers, res.ok ? res.data.status : res.error);
				if (length(answers) < 12)
					return uloop.timer(150, fetch);
				churning.cancel();
				for (let s in held)
					s.close();
				uloop.timer(100, () => uloop.end());
			});
		}
		uloop.timer(50, fetch);
		uloop.run();
		guard.cancel();
		let left = server.connections();
		server.close();
		assert.match(map([ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 ], () => 200), answers);
		assert.match(0, left, 'every connection closed once its client left');
	});
});
