'use strict';

// deps.create(): the real fs, uci, ubus, uloop, socket, rtnl, http, clock, exec runner and syslog.

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

export function route_get(host) {
	let route = rtnl.request(rtnl.const.RTM_GETROUTE, 0, { dst: host });
	return route ? Result.ok(route) : Result.err(errors.ROUTE_LOOKUP_FAILED, `${host}: ${rtnl.error()}`);
};

const PRIORITIES = { error: log.LOG_ERR, warn: log.LOG_WARNING, info: log.LOG_INFO, debug: log.LOG_DEBUG };

export function syslog_channel() {
	log.openlog('wgpathd', log.LOG_PID, log.LOG_DAEMON);
	return function(level, msg) {
		log.syslog(PRIORITIES[level] ?? log.LOG_INFO, msg);
	};
};

// uloop is initialised before connecting, so the ubus connection joins the loop.
export function create() {
	uloop.init();
	return {
		fs: fs,
		uci: uci.cursor(),
		ubus: ubus_channel(ubus.connect()),
		uloop: uloop,
		socket: socket,
		route_get: route_get,
		http: http.create(uclient, uloop),
		clock: clock.create(),
		exec: exec.create(uloop),
		log: syslog_channel(),
		stderr: (msg) => warn(`wgpathd: ${msg}\n`),
	};
};
