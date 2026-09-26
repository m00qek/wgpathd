'use strict';

// with_context(cfg, cb): inject the mocks named in cfg (strict by default) and
// call cb with a fake `deps` built from them. cfg maps a mock name to its utest
// state, e.g. { clock: { data: { now: 10 } }, uci: { data: {...} } }.
import { mock } from 'utest';

function build_deps(proxies) {
	let deps = { log: function(level, msg) {} };

	if (proxies.fs)    deps.fs    = proxies.fs;
	if (proxies.uci)   deps.uci   = proxies.uci.cursor();
	if (proxies.ubus)  deps.ubus  = proxies.ubus.connect();
	if (proxies.uloop) deps.uloop = proxies.uloop;
	if (proxies.clock) deps.clock = proxies.clock.create();

	return deps;
}

function inject_each(cfg, names, proxies, cb) {
	if (length(names) == 0)
		return cb(build_deps(proxies));

	let name = names[0];
	mock.inject(name, { strict: true, ...(cfg[name] || {}) }, function(proxy) {
		proxies[name] = proxy;
		inject_each(cfg, slice(names, 1), proxies, cb);
	});
}

export function with_context(cfg, cb) {
	inject_each(cfg, keys(cfg), {}, cb);
};
