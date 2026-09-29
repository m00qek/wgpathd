'use strict';

// Hand-built fakes for driving the daemon: exec by argv, ICMP probes, ubus, http, fs, clock, log,
// uloop, and a fake kernel and network ("world") that answers all of them consistently; and
// real UCI files for the uci module.

import * as Result from 'wgpathd.result';
import { mkdtemp, writefile } from 'fs';

export const WATCHDOG_PING = { obj: 'service', method: 'watchdog', args: { name: 'wgpathd', instance: 'wgpathd' } };

function as_result(answer) {
	return Result.is(answer) ? answer : Result.ok(answer);
}

// Answers each command through answer(argv). Immediate mode calls back at once;
// deferred mode queues callbacks until flush(), to observe what runs concurrently.
// `deferred` may be switched at any time.
export function exec(answer, deferred) {
	let fake = { calls: [], pending: [], deferred: deferred };
	fake.run = function(argv, timeout, cb) {
		push(fake.calls, { argv: argv, timeout: timeout });
		if (!fake.deferred)
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

// Answers each probe through answer(probe): true, false or a Result error. Deferred
// mode queues the answers until flush(), in the order the probes were sent.
export function icmp(answer, deferred) {
	let fake = { sent: [], pending: [], deferred: deferred };
	let resolver = (p, cb) => function() {
		let a = answer(p);
		cb(p, Result.is(a) ? a : Result.ok(a));
	};
	fake.send = function(probes, timeout, cb) {
		for (let p in probes) {
			push(fake.sent, { host: p.host, size: p.size, device: p.device, timeout: timeout });
			let resolve = resolver(p, cb);
			if (fake.deferred)
				push(fake.pending, resolve);
			else
				resolve();
		}
	};
	fake.flush = function() {
		let batch = fake.pending;
		fake.pending = [];
		for (let resolve in batch)
			resolve();
		return length(batch);
	};
	fake.hosts = () => map(fake.sent, (p) => p.host);
	return fake;
};

// Deferred mode answers a deferred call when it is made but delivers the answer only
// on flush(), like an rpcd reply waiting in the socket.
export function ubus(answer, deferred) {
	let fake = { calls: [], published: {}, pending: [], deferred: deferred };
	let respond = function(obj, method, args) {
		push(fake.calls, { obj: obj, method: method, args: args });
		return answer(obj, method, args);
	};
	fake.call = respond;
	fake.defer = function(obj, method, args, cb) {
		let res = respond(obj, method, args);
		if (!fake.deferred)
			return cb(res);
		push(fake.pending, () => cb(res));
	};
	fake.flush = function() {
		let batch = fake.pending;
		fake.pending = [];
		for (let resolve in batch)
			resolve();
		return length(batch);
	};
	fake.status_reads = () => length(filter(fake.calls, (c) => c.obj == 'wireguard'));
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

// Files by path, in directories that root owns with mode 0700 unless `dirs` says
// otherwise ({ <path>: { uid, mode } }); `links` holds the symbolic links.
export function fs(files) {
	let fake = { files: { ...files }, dirs: {}, links: {}, modes: {} };
	let holds_files = (dir) => length(filter(keys(fake.files), (f) => index(f, dir + '/') == 0)) > 0;
	fake.readfile = (path) => fake.files[path];
	fake.lstat = function(path) {
		if (fake.links[path] != null)
			return { type: 'link', uid: 0, mode: 0o777 };
		if (fake.files[path] != null)
			return { type: 'file', uid: 0, mode: fake.modes[path] ?? 0o600 };
		if (fake.dirs[path] != null || holds_files(path))
			return { type: 'directory', uid: 0, mode: 0o700, ...(fake.dirs[path] ?? {}) };
		return null;
	};
	fake.mkdir = function(path, mode) {
		if (fake.lstat(path) != null)
			return null;
		fake.dirs[path] = { uid: 0, mode: mode };
		return true;
	};
	fake.chmod = function(path, mode) {
		if (fake.dirs[path] != null)
			fake.dirs[path].mode = mode;
		else
			fake.modes[path] = mode;
		return true;
	};
	fake.open = function(path, flags, mode) {
		if (index(flags, 'x') >= 0 && fake.lstat(path) != null)
			return null;
		fake.files[path] = '';
		fake.modes[path] = mode;
		return {
			write: function(data) {
				fake.files[path] += data;
				return length(data);
			},
			close: () => true,
		};
	};
	fake.unlink = function(path) {
		delete fake.files[path];
		delete fake.links[path];
		return true;
	};
	fake.rename = function(from, to) {
		fake.files[to] = fake.files[from];
		fake.modes[to] = fake.modes[from];
		delete fake.files[from];
		return true;
	};
	fake.error = () => 'Operation not permitted';
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
// test may change between loads. A null type visits every section, as in uci.
export function uci(data) {
	let fake = { data: data };
	let section = (pkg, sec) => fake.data[pkg]?.[sec];
	fake.cursor = () => ({
		get: (pkg, sec, opt) => (opt == null) ? section(pkg, sec)?.['.type'] : section(pkg, sec)?.[opt],
		get_all: (pkg, sec) => section(pkg, sec) ? { ...section(pkg, sec), '.name': sec } : null,
		foreach: function(pkg, stype, cb) {
			for (let name, s in fake.data[pkg] ?? {})
				if (stype == null || s['.type'] == stype)
					cb({ ...s, '.name': name });
		},
	});
	return fake;
};

function uci_value(v) {
	return "'" + replace(`${v}`, "'", "'\\''") + "'";
}

// Writes `data`, as uci() takes it, as UCI files into a new directory for the real uci
// module (uci.cursor(dir)), and returns the directory. A section with '.anonymous' set
// gets no name.
export function uci_dir(data) {
	let dir = mkdtemp('/tmp/wgpathd-uci-XXXXXX');
	for (let pkg, sections in data) {
		let text = '';
		for (let name, s in sections) {
			text += `config ${s['.type']}` + (s['.anonymous'] ? '' : ` ${uci_value(name)}`) + '\n';
			for (let opt, v in s)
				if (substr(opt, 0, 1) != '.' && v != null)
					for (let item in (type(v) == 'array') ? v : [ v ])
						text += `\t${(type(v) == 'array') ? 'list' : 'option'} ${opt} ${uci_value(item)}\n`;
			text += '\n';
		}
		writefile(`${dir}/${pkg}`, text);
	}
	return dir;
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
// `wireguard status` reports and the batched `wg set` writes (all of it, or with
// `set_code` != 0 none of it); routes default to dev wg_hub for IPv4 and wan for
// IPv6 (the relays and the direct paths), hosts in `local` are the router's own,
// and hosts in `unrouted` fail the lookup; the mesh interface has MTU `mtu` (null:
// the lookup fails). A probe is answered when its host is in `reachable` and it fits
// the path: `max_size` caps the payload that gets through, `send_error[host]` fails
// the send; `on_probe(probe)`, if set, runs as each probe is answered. `status_ok`
// false fails every `wireguard status` read; `answer_read_ok` false fails only the
// reads made after a tunnel probe was answered, until the cycle ends with its
// watchdog ping.
// Discovery returns `payload` (null: the fetch fails).
export function world(kernel, opts) {
	opts ??= {};
	let w = {
		iface: opts.iface ?? 'wg_mesh',
		kernel: kernel,
		routes: {},
		local: {},
		unrouted: {},
		reachable: {},
		max_size: null,
		send_error: {},
		mtu: 1360,
		payload: null,
		http_status: 200,
		status_ok: true,
		answer_read_ok: true,
		answered: false,
		set_code: 0,
		on_probe: null,
		watchdog: Result.ok(null),
	};

	let run_command = function(argv) {
		if (argv[0] != 'wg' || argv[1] != 'set')
			die(`unexpected command: ${join(' ', argv)}`);
		if (w.set_code == 0)
			for (let i = 3; i < length(argv); i += 4)
				w.kernel[argv[i + 1]].endpoint = argv[i + 3];
		return { code: w.set_code };
	};

	let answer_probe = function(p) {
		if (w.send_error[p.host])
			return Result.err('PROBE_SEND_FAILED', `${p.host}: ${w.send_error[p.host]}`);
		if (!w.reachable[p.host] || (w.max_size != null && p.size > w.max_size))
			return false;
		if (w.on_probe)
			w.on_probe(p);
		w.answered ||= p.device != null;
		return true;
	};

	let ubus_answer = function(obj, method) {
		if (obj == 'wireguard' && method == 'status')
			return (w.status_ok && (w.answer_read_ok || !w.answered))
				? Result.ok(status_reply(w.iface, w.kernel))
				: Result.err('UBUS_CALL_FAILED', 'wireguard status: status 4');
		if (obj == 'service' && method == 'watchdog') {
			w.answered = false;
			return w.watchdog;
		}
		die(`unexpected ubus call: ${obj} ${method}`);
	};

	let fetch = function(url) {
		if (w.payload == null)
			return Result.err('DISCOVERY_FETCH_FAILED', 'uclient error 4');
		return Result.ok({ status: w.http_status, body: w.payload });
	};

	w.exec = exec(run_command, opts.deferred);
	w.icmp = icmp(answer_probe, opts.deferred);
	w.ubus = ubus(ubus_answer, opts.ubus_deferred);
	w.http = http(fetch, opts.http_deferred);
	w.fs = fs(opts.files ?? {});
	w.clock = clock(100, 1790456500);
	w.logs = logger();
	w.deps = {
		exec: w.exec.run,
		icmp: w.icmp,
		link_mtu: (dev) => (w.mtu != null)
			? Result.ok(w.mtu)
			: Result.err('LINK_LOOKUP_FAILED', `${dev}: interface not found`),
		ubus: w.ubus,
		http: w.http,
		fs: w.fs,
		clock: w.clock,
		log: w.logs.log,
		route_get: function(host) {
			if (w.unrouted[host])
				return Result.err('ROUTE_LOOKUP_FAILED', `${host}: Network unreachable`);
			if (w.local[host])
				return Result.ok({ dst: host, oif: 'lo', local: true });
			return Result.ok({ dst: host, oif: w.routes[host] ?? ((index(host, ':') >= 0) ? 'wan' : 'wg_hub'), local: false });
		},
	};
	return w;
};
