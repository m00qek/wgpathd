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
