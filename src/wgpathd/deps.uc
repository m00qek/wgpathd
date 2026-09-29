'use strict';

// deps.create(): the real fs, uci, ubus, uloop, socket, rtnl, http, clock, exec runner, ICMP prober and syslog;
// deps.oneshot(): the subset a one-shot tool needs; deps.plugin(): the subset the rpcd plugin needs.

import * as fs from 'fs';
import * as uci from 'uci';
import * as ubus from 'ubus';
import * as uloop from 'uloop';
import * as socket from 'socket';
import * as rtnl from 'rtnl';
import * as uclient from 'uclient';
import * as log from 'log';
import * as clock from 'wgpathd.components.clock';
import * as exec from 'wgpathd.components.exec';
import * as http from 'wgpathd.components.http';
import * as icmp from 'wgpathd.components.icmp';
import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';

// A null reply is not a failure by itself: methods without data return null, and
// only conn.error() tells that success apart from a failed call.
export function ubus_channel(conn) {
	return {
		call: (obj, method, args) => {
			if (!conn)
				return Result.err(errors.UBUS_CONNECT_FAILED);
			let res = conn.call(obj, method, args);
			if (res === null) {
				let e = conn.error();
				if (e)
					return Result.err(errors.UBUS_CALL_FAILED, e);
			}
			return Result.ok(res);
		},
		defer: (obj, method, args, cb) => {
			if (!conn)
				return cb(Result.err(errors.UBUS_CONNECT_FAILED));
			let req = conn.defer(obj, method, args, (rc, data) => {
				cb((rc == 0) ? Result.ok(data) : Result.err(errors.UBUS_CALL_FAILED, `${obj} ${method}: status ${rc}`));
			});
			if (!req)
				cb(Result.err(errors.UBUS_CALL_FAILED, conn.error()));
		},
		publish: (name, methods) => {
			if (!conn)
				return Result.err(errors.UBUS_CONNECT_FAILED);
			let obj = conn.publish(name, methods);
			return obj ? Result.ok(obj) : Result.err(errors.UBUS_PUBLISH_FAILED, conn.error());
		},
	};
};

// `local` is true for an address of the router itself.
export function route_get(host) {
	let route = rtnl.request(rtnl.const.RTM_GETROUTE, 0, { dst: host });
	if (!route)
		return Result.err(errors.ROUTE_LOOKUP_FAILED, `${host}: ${rtnl.error()}`);
	return Result.ok({ ...route, local: route.type == rtnl.const.RTN_LOCAL });
};

export function link_mtu(dev) {
	let link = rtnl.request(rtnl.const.RTM_GETLINK, 0, { dev: dev });
	return link?.mtu ? Result.ok(link.mtu) : Result.err(errors.LINK_LOOKUP_FAILED, `${dev}: ${rtnl.error()}`);
};

// Returns a function giving n bytes from the kernel's generator, or null when it cannot be read.
export function random_source(fs) {
	let urandom = fs.open('/dev/urandom', 'r');
	return (n) => urandom?.read(n);
};

const PRIORITIES = { err: 'LOG_ERR', warning: 'LOG_WARNING', notice: 'LOG_NOTICE', info: 'LOG_INFO' };

// With a stderr handle, every message is echoed there as well, for a run in the foreground.
export function syslog_channel(log, stderr) {
	log.openlog('wgpathd', log.LOG_PID, log.LOG_DAEMON);
	return function(level, msg) {
		if (!exists(PRIORITIES, level))
			die(`unknown log level '${level}'`);
		log.syslog(log[PRIORITIES[level]], '%s', msg);
		stderr?.write(`${level}: ${msg}\n`);
	};
};

// procd captures stderr into syslog, so echoing there under procd would log everything twice.
function stderr_echo() {
	return (getenv('WGPATHD_STDERR') == '1' || fs.stderr.isatty()) ? fs.stderr : null;
}

// uloop is initialised before connecting, so the ubus connection joins the loop.
export function create() {
	uloop.init();
	return {
		fs: fs,
		uci_cursor: uci.cursor,   // a cursor caches what it read: each config load takes a new one
		ubus: ubus_channel(ubus.connect()),
		uloop: uloop,
		socket: socket,
		route_get: route_get,
		link_mtu: link_mtu,
		http: http.create(uclient, uloop),
		clock: clock.create(),
		exec: exec.create(uloop),
		icmp: icmp.create(socket, uloop, random_source(fs)),
		log: syslog_channel(log, stderr_echo()),
	};
};

export function oneshot() {
	return {
		uci: uci.cursor(),
		fs: fs,
		ubus: ubus_channel(ubus.connect()),
		route_get: route_get,
		log: syslog_channel(log, stderr_echo()),
	};
};

// No ubus: the rpcd plugin runs inside rpcd, which answers `wireguard status` itself.
export function plugin() {
	return {
		uci_cursor: uci.cursor,
		fs: fs,
		route_get: route_get,
	};
};
