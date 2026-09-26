import { describe, it, assert, contains } from 'utest';
import * as uloop from 'uloop';
import { readfile, unlink } from 'fs';
import * as exec from 'wgpathd.components.exec';

// Runs fn on a real loop, ending it after max_ms whatever happens. The guard is
// cancelled so it cannot end a later test's loop.
function on_loop(max_ms, fn) {
	uloop.init();
	let guard = uloop.timer(max_ms, () => uloop.end());
	fn();
	uloop.run();
	guard.cancel();
}

function run(argv, timeout, wait_ms) {
	let answers = [];
	on_loop(wait_ms ?? 3000, () => {
		exec.create(uloop)(argv, timeout, (res) => {
			push(answers, res);
			if (wait_ms == null)
				uloop.end();
		});
	});
	return answers;
}

describe('components.exec', () => {
	it('reports the exit code of the command', () => {
		assert.match([ contains({ ok: true, data: { code: 0 } }) ], run([ 'true' ], 2));
		assert.match([ contains({ ok: true, data: { code: 3 } }) ], run([ 'sh', '-c', 'exit 3' ], 2));
	});

	it('reports 127 for a command that does not exist', () => {
		assert.match([ contains({ ok: true, data: { code: 127 } }) ], run([ 'no-such-command-wgpathd' ], 2));
	});

	it('passes arguments verbatim, spaces and quotes included', () => {
		let out = `/tmp/exec_test_args.${time()}`;
		let args = [ 'a b', "it's", '"q" $HOME', '' ];
		run([ 'sh', '-c', 'printf "%s|" "$@" > "$0"', out, ...args ], 2);
		assert.match(join('|', args) + '|', readfile(out));
		unlink(out);
	});

	it('reports a signalled command as a failure', () => {
		let answers = run([ 'sh', '-c', 'kill -9 $$' ], 2);
		assert.match(true, answers[0].data.code != 0);
	});

	it('gives up at the timeout with EXEC_TIMEOUT, exactly once', () => {
		let answers = run([ 'sleep', '2' ], 0.2, 2500);
		assert.match([ contains({ ok: false, error: 'EXEC_TIMEOUT', details: 'sleep' }) ], answers);
	});

	it('keeps the loop running while a command waits', () => {
		let events = [];
		on_loop(3000, () => {
			uloop.timer(100, () => push(events, 'tick'));
			exec.create(uloop)([ 'sleep', '1' ], 2, () => {
				push(events, 'done');
				uloop.end();
			});
		});
		assert.match([ 'tick', 'done' ], events);
	});
});
