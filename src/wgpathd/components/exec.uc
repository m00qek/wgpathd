'use strict';

// Exit-code-only command runner on uloop.process, with a timer backstop.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';

// The explicit exit keeps the shell from exec'ing the command, so a signalled command
// reports 128+n, where uloop would report 0.
const WRAPPER = '"$0" "$@" >/dev/null 2>&1; exit $?';

// A process cannot be killed from here, only forgotten, so every command must carry
// its own timeout.
export function create(uloop) {
	return function exec(argv, timeout, cb) {
		let done = false;
		let timer = null;
		let proc = null;

		// The timer and the exit can land in the same loop iteration. The callbacks of
		// each capture the other, so both are dropped here, or neither is ever freed;
		// and uloop keeps a timer that has fired until it is cancelled.
		let finish = function(res) {
			if (done)
				return;
			done = true;
			timer.cancel();
			timer = proc = null;
			cb(res);
		};

		proc = uloop.process('/bin/sh', [ '-c', WRAPPER, ...argv ], {}, (code) => finish(Result.ok({ code: code })));
		timer = uloop.timer(int(timeout * 1000), () => {
			proc.delete();
			finish(Result.err(errors.EXEC_TIMEOUT, argv[0]));
		});
	};
};
