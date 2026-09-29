#!/usr/bin/ucode
'use strict';

// Stands in for the wgpathd daemon in the browser tests. It publishes `wgpathd` with a
// `status` method that answers a fixture from $FIXTURES/<name>.json as it is, frozen
// `now` included, through the same ubus binding and method policy as the installed
// daemon; and `wgpathd.fixture` with `use {name}` to switch fixtures. The name `none`
// withdraws `wgpathd`, as when the daemon is not running.
//
// `wgpathd.fixture` also lays out the configuration the real rpcd plugin and LuCI read:
// `config {name}` writes /etc/config/network, /etc/config/wgpathd and /etc/config/firewall
// from $FIXTURES/config/<name>/, each file it has, or as they were at start for `default`
// and for a file it lacks; `read {config}` returns one of the three as it is on disk.

import * as ubus from 'ubus';
import * as uloop from 'uloop';
import { readfile, writefile } from 'fs';
import { STATUS_ARGS } from 'wgpathd.daemon';

const DIR = getenv('FIXTURES') ?? '/fixtures';
const CONFIGS = [ 'network', 'wgpathd', 'firewall' ];

uloop.init();
const conn = ubus.connect();
let reply = null;
let object = null;

let at_start = {};
for (let name in CONFIGS)
	at_start[name] = readfile(`/etc/config/${name}`);

function is_name(name) {
	return type(name) == 'string' && match(name, /^[a-z0-9-]+$/) != null;
}

function use(name) {
	if (name == 'none') {
		object?.remove();
		object = null;
		return true;
	}

	if (!is_name(name))
		return false;

	let data = readfile(`${DIR}/${name}.json`);
	if (data == null)
		return false;

	reply = json(data);
	object ??= conn.publish('wgpathd', { status: { args: STATUS_ARGS, call: () => reply } });
	return true;
}

function lay_out(name) {
	if (!is_name(name))
		return false;
	for (let config in CONFIGS) {
		let data = (name == 'default') ? null : readfile(`${DIR}/config/${name}/${config}`);
		if (writefile(`/etc/config/${config}`, data ?? at_start[config]) == null)
			return false;
	}
	return true;
}

conn.publish('wgpathd.fixture', {
	use: { args: { ...STATUS_ARGS, name: '' }, call: (req) => ({ ok: use(req.args.name) }) },
	config: { args: { ...STATUS_ARGS, name: '' }, call: (req) => ({ ok: lay_out(req.args.name) }) },
	read: {
		args: { ...STATUS_ARGS, config: '' },
		call: (req) => (req.args.config in CONFIGS) ? { data: readfile(`/etc/config/${req.args.config}`) } : { data: null },
	},
});

if (!use(getenv('FIXTURE') ?? 'spoke'))
	die(`no fixture ${getenv('FIXTURE') ?? 'spoke'} in ${DIR}`);

uloop.run();
