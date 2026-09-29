'use strict';

// Hub role: the discovery snapshot, the pure request -> response mapping, and a thin uloop TCP server.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import * as endpoint from 'wgpathd.endpoint';

export const MAX_CONNECTIONS = 16;
export const MAX_PER_SOURCE  = 2;
const MAX_REQUEST     = 4096;
const REQUEST_TIMEOUT = 2000;

const STATUS_TEXT = { '200': 'OK', '400': 'Bad Request', '404': 'Not Found', '405': 'Method Not Allowed' };

function entry(peer, wall) {
	if (peer.last_hs_ts == null)
		return { direct: peer.endpoint };
	return { direct: peer.endpoint, handshake_age: max(0, wall - peer.last_hs_ts) };
}

export function snapshot(peers, wall) {
	let out = {};
	for (let key, peer in peers)
		if (endpoint.is_v6(peer.endpoint))
			out[key] = entry(peer, wall);
	return out;
};

function reply(status, value) {
	let body = sprintf('%J', value);
	return `HTTP/1.0 ${status} ${STATUS_TEXT[status]}\r\n` +
		'Content-Type: application/json\r\n' +
		`Content-Length: ${length(body)}\r\n` +
		'Connection: close\r\n\r\n' + body;
}

export function respond(request, peers) {
	let m = match(request, /^([A-Z]+) ([^ \r\n]+) HTTP\/1\.[01]\r?\n/);
	if (!m)
		return reply(400, { error: 'bad request' });
	if (m[1] != 'GET')
		return reply(405, { error: 'method not allowed' });
	if (m[2] != '/peers')
		return reply(404, { error: 'not found' });
	return reply(200, peers);
};

function request_complete(buf) {
	return index(buf, '\r\n\r\n') >= 0 || index(buf, '\n\n') >= 0;
}

// Returns the connection's record, { source, close }; close runs once, whatever calls it.
function serve(deps, conn, source, peers_fn, on_close) {
	let sock = deps.socket;
	let buf = '';
	let handle = null;
	let timer = null;
	let record = { source: source };
	let closed = false;

	let close = function() {
		if (closed)
			return;
		closed = true;
		handle.delete();
		timer.cancel();
		conn.close();
		on_close(record);
	};
	record.close = close;

	let on_readable = function() {
		let chunk = conn.recv(MAX_REQUEST + 1 - length(buf), sock.MSG_DONTWAIT);
		if (!chunk)
			return close();
		buf += chunk;
		if (request_complete(buf)) {
			conn.send(respond(buf, peers_fn()), sock.MSG_DONTWAIT | sock.MSG_NOSIGNAL);
			close();
		}
		else if (length(buf) > MAX_REQUEST) {
			close();
		}
	};

	timer = deps.uloop.timer(REQUEST_TIMEOUT, close);
	handle = deps.uloop.handle(conn, on_readable, deps.uloop.ULOOP_READ);
	return record;
}

// peers_fn returns the current snapshot; the server never runs a command per request.
export function listen(deps, addr, port, peers_fn) {
	let sock = deps.socket;
	let server = sock.listen(addr, port, { socktype: sock.SOCK_STREAM }, MAX_CONNECTIONS, true);
	if (!server)
		return Result.err(errors.PUBLISHER_LISTEN_FAILED, `${addr}:${port}: ${sock.error()}`);

	// The connections still waiting for their request, oldest first: an answered one is
	// closed at once. A new one is always taken, so a client that holds connections
	// open cannot lock others out: it takes the place of the oldest from its own source
	// when that source already holds its share, else of the oldest of all when full.
	let open = [];
	let on_close = (record) => { open = filter(open, (r) => r != record); };
	let handle = deps.uloop.handle(server, () => {
		let peer = {};
		let conn = server.accept(peer);
		if (!conn)
			return;
		let source = endpoint.canonical_ip(peer.address);
		let own = filter(open, (r) => r.source == source);
		if (length(own) >= MAX_PER_SOURCE)
			own[0].close();
		else if (length(open) >= MAX_CONNECTIONS)
			open[0].close();
		push(open, serve(deps, conn, source, peers_fn, on_close));
	}, deps.uloop.ULOOP_READ);

	return Result.ok({
		connections: () => length(open),
		close: function() {
			for (let r in open)
				r.close();
			handle.delete();
			server.close();
		},
	});
};
