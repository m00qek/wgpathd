#!/usr/bin/env ucode
'use strict';

// `service wgpathd migrate`, also run once by /etc/uci-defaults/50-wgpathd-peers after
// an install or upgrade: moves the peer settings earlier releases kept in
// /etc/config/network into /etc/config/wgpathd.

import * as migrate from 'wgpathd.migrate';
import * as deps from 'wgpathd.deps';
import * as Result from 'wgpathd.result';

let d = deps.oneshot();
let res = migrate.run(d.uci, d.log);
if (!res.ok)
	d.log('err', `migrate: failed, /etc/config/network left as it was: ${Result.describe(res)}`);
exit(res.ok ? 0 : 1);
