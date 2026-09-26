import { describe, it, prop, gen, assert } from 'utest';
import * as Result from 'wgpathd.result';

describe('result: ok', () => {
	it('is ok and carries its data', () => {
		let res = Result.ok({ k: 'v' });
		assert.match(true, res.ok);
		assert.match({ k: 'v' }, res.data);
	});

	it('carries null for void operations', () => {
		assert.match(null, Result.ok(null).data);
	});

	prop('preserves any payload', gen.tuple(gen.int(-100, 100), gen.string({ max_len: 50 })), (p) => {
		assert.match(p, Result.ok(p).data);
	});
});

describe('result: err', () => {
	it('is not ok and carries code and details', () => {
		let res = Result.err('WG_PARSE_FAILED', { line: 3 });
		assert.match(false, res.ok);
		assert.match('WG_PARSE_FAILED', res.error);
		assert.match({ line: 3 }, res.details);
	});

	it('leaves details null when omitted', () => {
		assert.match(null, Result.err('PROBE_FAILED').details);
	});

	prop('preserves any code', gen.alphanumeric({ min_len: 1, max_len: 30 }), (code) => {
		assert.match(code, Result.err(code).error);
	});
});

describe('result: is', () => {
	prop('recognises every ok and err', gen.string({ max_len: 30 }), (s) => {
		assert.match(true, Result.is(Result.ok(s)));
		assert.match(true, Result.is(Result.err(s)));
	});

	it('rejects plain objects shaped like a Result', () => {
		assert.match(false, Result.is({ ok: true, data: 'x' }));
		assert.match(false, Result.is({ ok: false, error: 'E' }));
	});

	it('rejects non-objects', () => {
		for (let v in [ null, 'result', 42, [] ])
			assert.match(false, Result.is(v));
	});
});

describe('result: describe', () => {
	it('appends string details as the cause', () => {
		assert.match('DISCOVERY_FETCH_FAILED (TIMEOUT)', Result.describe(Result.err('DISCOVERY_FETCH_FAILED', 'TIMEOUT')));
	});

	it('shows only the code without details', () => {
		assert.match('PROBE_FAILED', Result.describe(Result.err('PROBE_FAILED')));
	});

	it('shows only the code for empty or non-string details', () => {
		assert.match('E', Result.describe(Result.err('E', '')));
		assert.match('E', Result.describe(Result.err('E', { status: 500 })));
	});
});
