#!/usr/bin/env ucode
'use strict';

// `service wgpathd check`. --config checks only /etc/config (what start and reload run).

import * as check from 'wgpathd.check';
import * as deps from 'wgpathd.deps';

let config_only = (ARGV[0] == '--config');
if (length(ARGV) > (config_only ? 1 : 0)) {
	warn('usage: check.uc [--config]\n');
	exit(2);
}

let res = check.run(deps.oneshot(), { config_only: config_only });
print(res.report);
exit(res.ok ? 0 : 1);
