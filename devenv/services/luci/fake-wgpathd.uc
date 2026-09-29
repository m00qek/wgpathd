#!/usr/bin/ucode
'use strict';

// Stands in for the wgpathd daemon in the browser tests. It publishes `wgpathd` with a
// `status` method that answers a fixture from $FIXTURES/<name>.json as it is, frozen
// `now` included, through the same ubus binding and method policy as the installed
// daemon; and `wgpathd.fixture` with `use {name}` to switch fixtures. The name `none`
// withdraws `wgpathd`, as when the daemon is not running.

import * as ubus from 'ubus';
import * as uloop from 'uloop';
import { readfile } from 'fs';
import { STATUS_ARGS } from 'wgpathd.daemon';

const DIR = getenv('FIXTURES') ?? '/fixtures';

uloop.init();
const conn = ubus.connect();
let reply = null;
let object = null;

function use(name) {
	if (name == 'none') {
		object?.remove();
		object = null;
		return true;
	}

	if (type(name) != 'string' || !match(name, /^[a-z0-9-]+$/))
		return false;

	let data = readfile(`${DIR}/${name}.json`);
	if (data == null)
		return false;

	reply = json(data);
	object ??= conn.publish('wgpathd', { status: { args: STATUS_ARGS, call: () => reply } });
	return true;
}

conn.publish('wgpathd.fixture', {
	use: { args: { ...STATUS_ARGS, name: '' }, call: (req) => ({ ok: use(req.args.name) }) },
});

if (!use(getenv('FIXTURE') ?? 'spoke'))
	die(`no fixture ${getenv('FIXTURE') ?? 'spoke'} in ${DIR}`);

uloop.run();
