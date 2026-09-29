import { describe, it, assert } from 'utest';
import { syslog_channel, random_source } from 'wgpathd.deps';

function fake_log() {
	return {
		LOG_PID: 1, LOG_DAEMON: 24, LOG_ERR: 3, LOG_WARNING: 4, LOG_NOTICE: 5, LOG_INFO: 6,
		opened: null, lines: [],
		openlog: function(ident, opts, facility) { this.opened = [ ident, opts, facility ]; },
		syslog: function(prio, fmt, ...args) { push(this.lines, [ prio, fmt, ...args ]); },
	};
}

function fake_stderr() {
	return { written: [], write: function(s) { push(this.written, s); } };
}

describe('deps: syslog_channel', () => {
	it('opens syslog as wgpathd with its PID under facility daemon', () => {
		let log = fake_log();
		syslog_channel(log);
		assert.match([ 'wgpathd', 1, 24 ], log.opened);
	});

	it('maps each level to its syslog priority', () => {
		let log = fake_log();
		let emit = syslog_channel(log);
		for (let level in [ 'err', 'warning', 'notice', 'info' ])
			emit(level, level);
		assert.match([ [ 3, '%s', 'err' ], [ 4, '%s', 'warning' ], [ 5, '%s', 'notice' ], [ 6, '%s', 'info' ] ], log.lines);
	});

	it('passes the message as an argument, never as the format', () => {
		let log = fake_log();
		syslog_channel(log)('info', 'probe loss 100%s %d');
		assert.match([ [ 6, '%s', 'probe loss 100%s %d' ] ], log.lines);
	});

	it('dies on an unknown level', () => {
		let log = fake_log();
		let emit = syslog_channel(log);
		for (let level in [ 'warn', 'error', 'debug', null ]) {
			let died = false;
			try {
				emit(level, 'x');
			}
			catch (e) {
				died = true;
			}
			assert.match(true, died, `level ${level}`);
		}
		assert.match([], log.lines);
	});

	it('echoes each message to stderr, prefixed by its level, when given a handle', () => {
		let stderr = fake_stderr();
		let emit = syslog_channel(fake_log(), stderr);
		emit('notice', 'started role=hub');
		emit('err', '100%s');
		assert.match([ 'notice: started role=hub\n', 'err: 100%s\n' ], stderr.written);
	});
});

describe('deps: random_source', () => {
	it('reads the bytes from /dev/urandom, opened once', () => {
		let opened = [];
		let fs = { open: function(path, mode) {
			push(opened, [ path, mode ]);
			return { read: (n) => substr('0123456789', 0, n) };
		} };
		let random = random_source(fs);
		assert.match([ '0123', '01234567' ], [ random(4), random(8) ]);
		assert.match([ [ '/dev/urandom', 'r' ] ], opened);
	});

	it('gives null when the device cannot be opened', () => {
		assert.match(null, random_source({ open: () => null })(8));
	});
});
