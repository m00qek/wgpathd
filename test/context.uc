'use strict';

// with_context(cfg, cb): inject the utest mocks named in cfg (strict by default)
// and call cb with a fake `deps` built from them. `clock` is not a mock: deps
// receive a plain fake clock, e.g. { clock: { now: 10 }, uci: { data: {...} } }.
import { mock } from 'utest';
import * as h from 'lib.helpers';

function build_deps(cfg, proxies) {
	let deps = { log: function(level, msg) {} };

	if (proxies.fs)    deps.fs    = proxies.fs;
	if (proxies.uci)   deps.uci   = proxies.uci.cursor();
	if (proxies.ubus)  deps.ubus  = proxies.ubus.connect();
	if (proxies.uloop) deps.uloop = proxies.uloop;
	if (cfg.clock)     deps.clock = h.clock(cfg.clock.now ?? 0, cfg.clock.wall ?? 0);

	return deps;
}

function inject_each(cfg, names, proxies, cb) {
	if (length(names) == 0)
		return cb(build_deps(cfg, proxies));

	let name = names[0];
	mock.inject(name, { strict: true, ...(cfg[name] || {}) }, function(proxy) {
		proxies[name] = proxy;
		inject_each(cfg, slice(names, 1), proxies, cb);
	});
}

export function with_context(cfg, cb) {
	inject_each(cfg, filter(keys(cfg), (k) => k != 'clock'), {}, cb);
};
