#!/usr/bin/ucode
'use strict';

// Stands in for procd's `system` ubus object, which is not running in the browser
// tests' container: LuCI's page header reads `system board`, and the Overview's
// System and Memory sections read `system board` and `system info`.

import * as ubus from 'ubus';
import * as uloop from 'uloop';

uloop.init();
const conn = ubus.connect();

const BOARD = {
	kernel: '6.12.0',
	hostname: 'office',
	system: 'x86_64',
	model: 'Browser test container',
	board_name: 'wgpathd-browser-tests',
	rootfs_type: 'overlay',
	release: {
		distribution: 'OpenWrt',
		version: '25.12.5',
		revision: 'r0',
		target: 'x86/64',
		description: 'OpenWrt 25.12.5',
	},
};

const MB = 1024 * 1024;

conn.publish('system', {
	board: { args: { ubus_rpc_session: '' }, call: () => BOARD },
	info: {
		args: { ubus_rpc_session: '' },
		call: () => ({
			localtime: time(),
			uptime: 22440,
			load: [ 8192, 4096, 2048 ],
			memory: { total: 512 * MB, free: 300 * MB, shared: 4 * MB, buffered: 8 * MB, available: 360 * MB, cached: 60 * MB },
			root: { total: 100 * 1024, free: 80 * 1024, used: 20 * 1024, avail: 80 * 1024 },
			tmp: { total: 256 * 1024, free: 250 * 1024, used: 6 * 1024, avail: 250 * 1024 },
			swap: { total: 0, free: 0 },
		}),
	},
});

uloop.run();
