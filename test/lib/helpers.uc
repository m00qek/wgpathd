'use strict';

// Hand-built fakes for driving the daemon: exec by argv, ubus, http, fs, clock, log, uloop, and a
// fake kernel and network ("world") that answers all of them consistently.

import * as Result from 'wgpathd.result';

export const WATCHDOG_PING = { obj: 'service', method: 'watchdog', args: { name: 'wgpathd', instance: 'wgpathd' } };

function as_result(answer) {
	return Result.is(answer) ? answer : Result.ok(answer);
}

// Answers each command through answer(argv). Immediate mode calls back at once;
// deferred mode queues callbacks until flush(), to observe what runs concurrently.
export function exec(answer, deferred) {
	let fake = { calls: [], pending: [] };
	fake.run = function(argv, timeout, cb) {
		push(fake.calls, { argv: argv, timeout: timeout });
		if (!deferred)
			return cb(as_result(answer(argv)));
		push(fake.pending, () => cb(as_result(answer(argv))));
	};
	fake.flush = function() {
		let batch = fake.pending;
		fake.pending = [];
		for (let resolve in batch)
			resolve();
		return length(batch);
	};
	fake.commands = () => map(fake.calls, (c) => join(' ', c.argv));
	return fake;
};

export function ubus(answer) {
	let fake = { calls: [], published: {} };
	let respond = function(obj, method, args) {
		push(fake.calls, { obj: obj, method: method, args: args });
		return answer(obj, method, args);
	};
	fake.call = respond;
	fake.defer = (obj, method, args, cb) => cb(respond(obj, method, args));
	fake.publish = function(name, methods) {
		fake.published[name] = methods;
		return Result.ok({});
	};
	fake.watchdog_pings = () => length(filter(fake.calls, (c) => c.obj == 'service'));
	return fake;
};

// Deferred mode holds each answer until flush(), like a hub that is slow or down.
export function http(answer, deferred) {
	let fake = { calls: [], pending: [] };
	fake.get = function(url, timeout_ms, max_bytes, cb) {
		push(fake.calls, url);
		if (!deferred)
			return cb(answer(url));
		push(fake.pending, () => cb(answer(url)));
	};
	fake.flush = function() {
		let batch = fake.pending;
		fake.pending = [];
		for (let resolve in batch)
			resolve();
	};
	return fake;
};

export function fs(files) {
	let fake = { files: { ...files } };
	fake.readfile = (path) => fake.files[path];
	fake.writefile = function(path, data) {
		fake.files[path] = data;
		return length(data);
	};
	fake.rename = function(from, to) {
		fake.files[to] = fake.files[from];
		delete fake.files[from];
		return true;
	};
	fake.mkdir = () => true;
	return fake;
};

export function clock(now, wall) {
	let fake = { t: now, w: wall };
	fake.now = () => fake.t;
	fake.wall = () => fake.w;
	fake.advance = function(s) {
		fake.t += s;
		fake.w += s;
	};
	return fake;
};

export function logger() {
	let fake = { entries: [] };
	fake.log = (level, msg) => push(fake.entries, [ level, msg ]);
	fake.matching = (re) => filter(fake.entries, (e) => match(e[1], re) != null);
	return fake;
};

// A uci cursor over `fake.data` ({ package: { section: { '.type', options } } }), which a
// test may change between loads.
export function uci(data) {
	let fake = { data: data };
	let section = (pkg, sec) => fake.data[pkg]?.[sec];
	fake.cursor = () => ({
		get: (pkg, sec, opt) => (opt == null) ? section(pkg, sec)?.['.type'] : section(pkg, sec)?.[opt],
		get_all: (pkg, sec) => section(pkg, sec) ? { ...section(pkg, sec), '.name': sec } : null,
		foreach: function(pkg, stype, cb) {
			for (let name, s in fake.data[pkg] ?? {})
				if (s['.type'] == stype)
					cb({ ...s, '.name': name });
		},
	});
	return fake;
};

export function uloop() {
	let fake = { timers: [], signals: {}, ran: false, ended: false };
	fake.timer = function(ms, cb) {
		push(fake.timers, { ms: ms, cb: cb });
		return { cancel: () => true };
	};
	// Fires the zero-delay timers, as the first turn of a real loop would.
	fake.run = function() {
		fake.ran = true;
		for (let t in filter(fake.timers, (t) => t.ms == 0))
			t.cb();
	};
	fake.end = function() { fake.ended = true; };
	fake.signal = function(name, cb) {
		fake.signals[name] = cb;
		return { delete: () => true };
	};
	return fake;
};

export function status_reply(iface, kernel) {
	let peers = {};
	for (let key, p in kernel) {
		peers[key] = { allowed_ips: [ '10.9.0.2/32' ], last_handshake: p.hs ?? 0, rx_bytes: 0, tx_bytes: 0 };
		if (p.endpoint != null)
			peers[key].endpoint = p.endpoint;
	}
	return { [iface]: { ifindex: 3, listen_port: -13716, peers: peers } };
};

// A fake kernel and network. `kernel` maps pubkey -> { endpoint, hs } and is what
// `wireguard status` reports and `wg set` writes; routes default to dev wg_hub, and
// hosts in `unrouted` fail the lookup;
// pings succeed for hosts in `reachable`, and `on_ping(host)`, if set, runs as each
// ping is answered; discovery returns `payload` (null: the fetch fails).
export function world(kernel, opts) {
	opts ??= {};
	let w = {
		iface: opts.iface ?? 'wg_mesh',
		kernel: kernel,
		routes: {},
		unrouted: {},
		reachable: {},
		payload: null,
		http_status: 200,
		status_ok: true,
		set_code: 0,
		on_ping: null,
		watchdog: Result.ok(null),
	};

	let run_command = function(argv) {
		if (argv[0] == 'wg') {
			if (w.set_code == 0)
				w.kernel[argv[4]].endpoint = argv[6];
			return { code: w.set_code };
		}
		if (argv[0] == 'ping') {
			let host = argv[length(argv) - 1];
			if (!w.reachable[host])
				return { code: 1 };
			if (w.on_ping)
				w.on_ping(host);
			return { code: 0 };
		}
		die(`unexpected command: ${join(' ', argv)}`);
	};

	let ubus_answer = function(obj, method) {
		if (obj == 'wireguard' && method == 'status')
			return w.status_ok ? Result.ok(status_reply(w.iface, w.kernel)) : Result.err('UBUS_CALL_FAILED', 'wireguard status: status 4');
		if (obj == 'service' && method == 'watchdog')
			return w.watchdog;
		die(`unexpected ubus call: ${obj} ${method}`);
	};

	let fetch = function(url) {
		if (w.payload == null)
			return Result.err('DISCOVERY_FETCH_FAILED', 'uclient error 4');
		return Result.ok({ status: w.http_status, body: w.payload });
	};

	w.exec = exec(run_command, opts.deferred);
	w.ubus = ubus(ubus_answer);
	w.http = http(fetch, opts.http_deferred);
	w.fs = fs(opts.files ?? {});
	w.clock = clock(100, 1790456500);
	w.logs = logger();
	w.deps = {
		exec: w.exec.run,
		ubus: w.ubus,
		http: w.http,
		fs: w.fs,
		clock: w.clock,
		log: w.logs.log,
		route_get: (host) => w.unrouted[host]
			? Result.err('ROUTE_LOOKUP_FAILED', `${host}: Network unreachable`)
			: Result.ok({ dst: `${host}/32`, oif: w.routes[host] ?? 'wg_hub' }),
	};
	return w;
};
