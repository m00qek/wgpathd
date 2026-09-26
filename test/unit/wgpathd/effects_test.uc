import { describe, it, prop, gen, assert } from 'utest';
import * as effects from 'wgpathd.effects';

const METRIC = { state: 'RELAY', up_streak: 0, down_streak: 0, backoff: 0, ready: false };

describe('effects: constructors', () => {
	it('builds the vocabulary shapes', () => {
		assert.match({ set_endpoint: '10.10.0.11:51820' }, effects.set_endpoint('10.10.0.11:51820'));
		assert.match({ tunnel_probe: '10.20.0.11' }, effects.tunnel_probe('10.20.0.11'));
		assert.match({ refresh_discovery: true }, effects.refresh_discovery());
		assert.match({ log: { event: 'transition', from: 'RELAY', to: 'TRIALING', reason: 'trial_start' } },
			effects.log('transition', 'RELAY', 'TRIALING', 'trial_start'));
		assert.match({ metric: METRIC }, effects.metric(METRIC));
	});

	it('metric copies only the vocabulary fields', () => {
		assert.match({ metric: METRIC }, effects.metric({ ...METRIC, target: 'x', asserted: 'y' }));
	});

	it('every constructor output validates', () => {
		assert.match(true, effects.validate([
			effects.set_endpoint('a'),
			effects.tunnel_probe('b'),
			effects.refresh_discovery(),
			effects.log('transition', 'DIRECT', 'RELAY', 'demoted'),
			effects.log('roam', 'DIRECT', 'DIRECT', 'roam_adopted'),
			effects.metric({ ...METRIC, state: 'DIRECT', up_streak: 2, down_streak: 1, backoff: 60, ready: true }),
		]));
	});

	it('an empty list is valid', () => {
		assert.match(true, effects.validate([]));
	});
});

describe('effects: validate rejects', () => {
	it('a non-list', () => {
		assert.match(false, effects.validate(null));
		assert.match(false, effects.validate({ set_endpoint: 'a' }));
	});

	it('effects outside the vocabulary', () => {
		for (let e in [
			{ set_allowed_ips: '0.0.0.0/0' },
			{ create_interface: 'wg1' },
			{ set_endpoint_hub: 'x' },
			{ exec: 'rm -rf /' },
		])
			assert.match(false, effects.validate([ e ]));
	});

	it('an effect carrying more than one kind', () => {
		assert.match(false, effects.validate([ { set_endpoint: 'a', tunnel_probe: 'b' } ]));
	});

	it('non-objects as effects', () => {
		for (let e in [ null, 'set_endpoint', 42, [ 'set_endpoint', 'a' ] ])
			assert.match(false, effects.validate([ e ]));
	});

	it('empty or non-string addresses', () => {
		for (let a in [ null, '', 42, {} ]) {
			assert.match(false, effects.validate([ { set_endpoint: a } ]));
			assert.match(false, effects.validate([ { tunnel_probe: a } ]));
		}
	});

	it('refresh_discovery with a payload', () => {
		assert.match(false, effects.validate([ { refresh_discovery: 'http://x' } ]));
	});

	it('logs with unknown states, reasons, events or fields', () => {
		let good = { event: 'transition', from: 'RELAY', to: 'TRIALING', reason: 'trial_start' };
		for (let bad in [
			{ ...good, from: 'UP' },
			{ ...good, to: null },
			{ ...good, reason: 'because' },
			{ ...good, event: 'noise' },
			{ ...good, extra: 1 },
			{ event: 'transition', from: 'RELAY', to: 'TRIALING' },
		])
			assert.match(false, effects.validate([ { log: bad } ]));
	});

	it('metrics with missing, extra or mistyped fields', () => {
		for (let bad in [
			{ ...METRIC, state: 'UP' },
			{ ...METRIC, up_streak: -1 },
			{ ...METRIC, down_streak: 1.5 },
			{ ...METRIC, backoff: -30 },
			{ ...METRIC, ready: 1 },
			{ ...METRIC, extra: 1 },
			{ state: 'RELAY', up_streak: 0, down_streak: 0, backoff: 0 },
		])
			assert.match(false, effects.validate([ { metric: bad } ]));
	});

	it('a list with one bad effect among good ones', () => {
		assert.match(false, effects.validate([ effects.set_endpoint('a'), { wg_hub_down: true } ]));
	});

	prop('any unknown kind', gen.alphanumeric({ min_len: 1, max_len: 20 }), (k) => {
		let e = {};
		e[k] = 'x';
		let known = k in [ 'set_endpoint', 'tunnel_probe' ];
		assert.match(known, effects.validate([ e ]));
	});
});
