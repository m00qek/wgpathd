#!/usr/bin/env ucode
'use strict';

// Prints the running daemon's status as text; `ubus call wgpathd status` is the JSON form.

import * as ubus from 'ubus';
import * as deps from 'wgpathd.deps';
import * as Result from 'wgpathd.result';
import { render } from 'wgpathd.status_view';

let res = deps.ubus_channel(ubus.connect()).call('wgpathd', 'status', {});
if (!res.ok) {
	warn(`wgpathd: cannot read status: ${Result.describe(res)}\n`);
	exit(1);
}
print(render(res.data, time()));
