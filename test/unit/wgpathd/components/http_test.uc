import { describe, it, assert, contains } from 'utest';
import * as uloop from 'uloop';
import * as uclient from 'uclient';
import * as socket from 'socket';
import * as http from 'wgpathd.components.http';

const PORT = 17781;
const URL  = `http://127.0.0.1:${PORT}/peers`;

// A loopback server that answers every request with `raw` (null: never answers).
function serve(raw) {
	let server = socket.listen('127.0.0.1', PORT, { socktype: socket.SOCK_STREAM }, 4, true);
	let clients = [];
	let answer = (conn) => uloop.handle(conn, () => {
		conn.recv(4096, socket.MSG_DONTWAIT);
		if (raw != null)
			conn.send(raw, socket.MSG_NOSIGNAL);
	}, uloop.ULOOP_READ);
	let handle = uloop.handle(server, () => {
		let conn = server.accept();
		push(clients, { conn: conn, handle: answer(conn) });
	}, uloop.ULOOP_READ);
	return () => {
		handle.delete();
		for (let c in clients) {
			c.handle.delete();
			c.conn.close();
		}
		server.close();
	};
}

function get(raw, timeout_ms, max_bytes) {
	let answers = [];
	uloop.init();
	let stop = serve(raw);
	let guard = uloop.timer(3000, () => uloop.end());
	http.create(uclient, uloop).get(URL, timeout_ms, max_bytes, (res) => {
		push(answers, res);
		uloop.timer(200, () => uloop.end());
	});
	uloop.run();
	guard.cancel();
	stop();
	return answers;
}

function response(status, body) {
	return `HTTP/1.0 ${status}\r\nContent-Length: ${length(body)}\r\nConnection: close\r\n\r\n${body}`;
}

describe('components.http: get', () => {
	it('returns the status and body', () => {
		assert.match([ contains({ ok: true, data: { status: 200, body: '{"a": 1}' } }) ],
			get(response('200 OK', '{"a": 1}'), 1000, 1024));
	});

	it('returns a non-200 status as data, for the caller to judge', () => {
		assert.match([ contains({ ok: true, data: { status: 404, body: 'x' } }) ],
			get(response('404 Not Found', 'x'), 1000, 1024));
	});

	it('fails once on a body larger than max_bytes', () => {
		assert.match([ contains({ ok: false, error: 'DISCOVERY_FETCH_FAILED', details: 'response too large' }) ],
			get(response('200 OK', 'abcdefghij'), 1000, 4));
	});

	it('fails once when the server never answers', () => {
		let answers = get(null, 300, 1024);
		assert.match(1, length(answers));
		assert.match(contains({ ok: false, error: 'DISCOVERY_FETCH_FAILED' }), answers[0]);
	});

	it('fails once when nothing listens', () => {
		let answers = [];
		http.create(uclient, uloop).get('http://127.0.0.1:17799/peers', 300, 1024, (res) => push(answers, res));
		assert.match([ contains({ ok: false, error: 'DISCOVERY_FETCH_FAILED', details: 'cannot connect' }) ], answers);
	});

	it('rejects an invalid url without showing its credentials', () => {
		let answers = [];
		http.create(uclient, uloop).get('ftp://user:secret@10.10.0.1/peers', 300, 1024, (res) => push(answers, res));
		assert.match([ contains({ ok: false, error: 'DISCOVERY_FETCH_FAILED', details: 'invalid url ftp://10.10.0.1/peers' }) ],
			answers);
	});
});
