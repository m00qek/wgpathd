#!/usr/bin/env ucode
'use strict';

// Run by procd (/etc/init.d/wgpathd); SIGHUP reloads the configuration.

import * as daemon from 'wgpathd.daemon';
import * as deps from 'wgpathd.deps';

exit(daemon.run(deps.create()));
