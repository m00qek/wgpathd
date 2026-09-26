import { describe, it, assert, spy } from 'utest';
import { with_context } from 'context';

describe('context: with_context', () => {
	it('injects a fake clock whose now() is read back through deps', () => {
		with_context({ clock: { data: { now: 1234.5 } } }, (deps) => {
			assert.match(1234.5, deps.clock.now());
		});
	});

	it('lets a behavior advance the fake clock', () => {
		let t = 100;
		with_context({ clock: { behavior: { now: () => t += 5 } } }, (deps) => {
			assert.match(105, deps.clock.now());
			assert.match(110, deps.clock.now());
		});
	});

	it('records clock calls for spy()', () => {
		with_context({ clock: {} }, (deps) => {
			deps.clock.now();
			deps.clock.now();
			assert.match(2, length(spy(deps.clock).calls.now));
		});
	});

	it('defaults the fake clock to 0', () => {
		with_context({ clock: {} }, (deps) => {
			assert.match(0, deps.clock.now());
		});
	});

	it('exposes http_client as deps.http', () => {
		let body = { peer: { direct: '[2001:db8::1]:51820' } };
		with_context({ http_client: { data: { 'http://hub/peers': { body } } } }, (deps) => {
			let res = deps.http.get('http://hub/peers');
			assert.match(true, res.ok);
			assert.match(200, res.data.status);
			assert.match(body, json(res.data.body));
		});
	});

	it('wires only the injected deps plus a no-op log', () => {
		with_context({ clock: {} }, (deps) => {
			assert.match([ 'clock', 'log' ], sort(keys(deps)));
			assert.match(null, deps.log('info', 'ignored'));
		});
	});
});
