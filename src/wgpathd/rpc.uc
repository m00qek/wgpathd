'use strict';

// The `wgpathd.config` ubus object, which rpcd serves through
// /usr/share/rpcd/ucode/wgpathd.uc whether or not the daemon runs.
//
//   check {}                          -> { ok, findings: [ { level, subject, section?, option?, message } ] }
//   check { candidate: { main, peers } } the same, for unsaved values over the committed config
//
// A malformed candidate is answered { error: "CHECK_INVALID_CANDIDATE", message }.

import * as check from 'wgpathd.check';
import { overlay } from 'wgpathd.candidate';

// A fresh cursor per call: rpcd outlives any number of commits.
export function run_check(deps, candidate) {
	let uci = deps.uci_cursor();
	if (candidate != null) {
		let view = overlay(uci, candidate);
		if (!view.ok)
			return { error: view.error, message: view.details };
		uci = view.data;
	}
	let res = check.run({ uci: uci, route_get: deps.route_get });
	return { ok: res.ok, findings: res.findings };
};

export function methods(deps) {
	return {
		check: {
			args: { candidate: {} },
			call: (req) => run_check(deps, req.args?.candidate),
		},
	};
};
