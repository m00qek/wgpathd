import { describe, it, prop, gen, assert } from 'utest';
import * as Result from 'wgpathd.result';
import * as probe from 'wgpathd.probe';

describe('probe: wait_seconds and backstop', () => {
	it('rounds the timeout up to whole seconds, at least one', () => {
		assert.match([ 1, 1, 1, 2, 2, 3 ], map([ 0.2, 0.5, 1, 1.5, 2, 2.01 ], probe.wait_seconds));
	});

	prop('gives the runner a backstop just above ping\'s own wait', gen.int(1, 50), (tenths) => {
		let t = tenths / 10;
		assert.match(true, probe.backstop(t) > probe.wait_seconds(t) && probe.wait_seconds(t) >= t);
	});
});

describe('probe: underlay_command', () => {
	it('pings the host of a direct endpoint over IPv6, once, waiting tunnel_timeout', () => {
		assert.match([ 'ping', '-6', '-c1', '-W1', '2001:db8::a' ], probe.underlay_command('[2001:db8::a]:51820', 1));
		assert.match([ 'ping', '-6', '-c1', '-W3', '2001:db8::a' ], probe.underlay_command('[2001:db8::a]:51820', 2.5));
	});

	it('pings the canonical host', () => {
		assert.match([ 'ping', '-6', '-c1', '-W1', 'fd42:7770:1::3' ], probe.underlay_command('[FD42:7770:1:0::3]:51820', 1));
	});

	it('has no underlay probe for an IPv4 or invalid endpoint', () => {
		for (let v in [ '10.10.0.12:51820', '2001:db8::a', null, '' ])
			assert.match(null, probe.underlay_command(v, 1));
	});
});

describe('probe: tunnel_command', () => {
	it('pings the tunnel address once, waiting tunnel_timeout', () => {
		assert.match([ 'ping', '-c1', '-W1', '10.20.0.12' ], probe.tunnel_command('10.20.0.12', 1));
		assert.match([ 'ping', '-c1', '-W2', '10.20.0.12' ], probe.tunnel_command('10.20.0.12', 2));
	});
});

describe('probe: reachable', () => {
	it('is true only when ping exits 0', () => {
		assert.match(true, probe.reachable(Result.ok({ code: 0, stdout: '' })));
	});

	prop('is false for any non-zero exit', gen.int(1, 255), (code) => {
		assert.match(false, probe.reachable(Result.ok({ code: code, stdout: '' })));
	});

	it('is false when the runner failed or gave nothing', () => {
		assert.match(false, probe.reachable(Result.err('EXEC_TIMEOUT', 'ping')));
		assert.match(false, probe.reachable(null));
		assert.match(false, probe.reachable(Result.ok(null)));
	});
});
