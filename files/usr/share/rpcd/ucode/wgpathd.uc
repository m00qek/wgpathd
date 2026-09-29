'use strict';

// rpcd ucode plugin: the `wgpathd.config` ubus object (wgpathd.rpc). rpcd loads it when it
// starts or reloads, so it answers whether or not the daemon runs or is enabled.

import * as rpc from 'wgpathd.rpc';
import * as deps from 'wgpathd.deps';

return { 'wgpathd.config': rpc.methods(deps.plugin()) };
