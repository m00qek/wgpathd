import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_context } from 'context';
import * as discovery from 'wgpathd.discovery';

const KEY_A = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const KEY_B = 'ckRTxoRCqAhiHEgHPnhfpN6nU5/F2QmMe0nJ2kt7PFc=';
const CACHE = '/var/run/wgpathd/cache.json';

const KEY  = gen.map(gen.string({ len: 43, charset: 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/' }), (s) => s + '=');
const V6   = gen.map(gen.array(gen.int(0, 255), { len: 16 }), arrtoip);
const PEER = gen.tuple(KEY, V6, gen.int(1, 65535), gen.optional(gen.int(0, 100000)));

const BAD_VALUES = [
	null, 'x', 7, [], {},
	{ direct: null }, { direct: '10.10.0.12:51820' }, { direct: '[2001:db8::1]' },
	{ direct: '[2001:db8::1]:0' }, { direct: '[2001:db8::1]:65536' }, { direct: '2001:db8::1' },
	{ direct: '[2001:db8::1]:51820', handshake_age: -1 },
	{ direct: '[2001:db8::1]:51820', handshake_age: 1.5 },
	{ direct: '[2001:db8::1]:51820', handshake_age: '7' },
	{ direct: '[2001:db8::1]:51820', handshake_age: null },
];

function payload_of(peers) {
	let out = {};
	for (let p in peers)
		out[p[0]] = (p[3] == null) ? { direct: `[${p[1]}]:${p[2]}` } : { direct: `[${p[1]}]:${p[2]}`, handshake_age: p[3] };
	return out;
}

function spaces(n) {
	let s = ' ';
	while (length(s) < n)
		s += s;
	return substr(s, 0, n);
}

function parse_json(v) {
	return discovery.parse(sprintf('%J', v));
}

describe('discovery: parse accepts', () => {
	it('a payload of direct endpoints with handshake ages', () => {
		let res = parse_json({ [KEY_A]: { direct: '[2001:db8::a]:51820', handshake_age: 7 },
			[KEY_B]: { direct: '[2001:db8::b]:40000' } });
		assert.match({ [KEY_A]: { direct: '[2001:db8::a]:51820', handshake_age: 7 },
			[KEY_B]: { direct: '[2001:db8::b]:40000' } }, res.data);
	});

	it('an empty object', () => {
		assert.match({}, discovery.parse('{}').data);
	});

	it('handshake_age 0', () => {
		assert.match(0, parse_json({ [KEY_A]: { direct: '[2001:db8::a]:1', handshake_age: 0 } }).data[KEY_A].handshake_age);
	});

	it('canonicalizes direct endpoints', () => {
		let res = parse_json({ [KEY_A]: { direct: '[2001:DB8:0:0::A]:051' } });
		assert.match('[2001:db8::a]:51', res.data[KEY_A].direct);
	});

	it('drops unknown fields', () => {
		let res = parse_json({ [KEY_A]: { direct: '[2001:db8::a]:1', relay: '10.0.0.1:1', extra: {} } });
		assert.match({ [KEY_A]: { direct: '[2001:db8::a]:1' } }, res.data);
	});

	it('exactly 64 peers and exactly 64 KiB', () => {
		let peers = {};
		for (let i = 0; i < 64; i++)
			peers[sprintf('%043d=', i)] = { direct: `[2001:db8::${i + 1}]:51820` };
		assert.match(true, parse_json(peers).ok);

		let body = sprintf('%J', { [KEY_A]: { direct: '[2001:db8::a]:1' } });
		body += spaces(65536 - length(body));
		assert.match(65536, length(body));
		assert.match(true, discovery.parse(body).ok);
	});

	prop('any valid generated payload, canonicalized', gen.array(PEER, { max_len: 10 }), (peers) => {
		let payload = payload_of(peers);
		assert.match(payload, parse_json(payload).data);
	});
});

describe('discovery: parse rejects the whole payload', () => {
	it('when stdout is not a JSON object', () => {
		for (let s in [ null, '', 'not json', '[]', '"x"', '7', 'null', '{} trailing', '{"a":' ])
			assert.match(contains({ ok: false, error: 'DISCOVERY_INVALID_JSON' }), discovery.parse(s), s);
	});

	it('when stdout exceeds 64 KiB, even if valid', () => {
		let body = '{' + spaces(65535) + '}';
		assert.match(65537, length(body));
		assert.match(contains({ ok: false, error: 'DISCOVERY_INVALID_JSON' }), discovery.parse(body));
	});

	it('when it has more than 64 peers', () => {
		let peers = {};
		for (let i = 0; i < 65; i++)
			peers[sprintf('%043d=', i)] = { direct: `[2001:db8::${i + 1}]:51820` };
		assert.match(contains({ ok: false, error: 'DISCOVERY_INVALID_PEERS' }), parse_json(peers));
	});

	it('when a key is not a WireGuard public key', () => {
		for (let key in [ 'peer', substr(KEY_A, 1), KEY_A + 'A', replace(KEY_A, '=', 'A'), replace(KEY_A, '/', '_') ])
			assert.match(contains({ ok: false, error: 'DISCOVERY_INVALID_PEERS' }),
				parse_json({ [KEY_B]: { direct: '[2001:db8::b]:1' }, [key]: { direct: '[2001:db8::a]:1' } }), key);
	});

	it('when a value is invalid', () => {
		for (let v in BAD_VALUES)
			assert.match(contains({ ok: false, error: 'DISCOVERY_INVALID_PEERS', details: KEY_A }),
				parse_json({ [KEY_B]: { direct: '[2001:db8::b]:1' }, [KEY_A]: v }));
	});

	prop('when any one entry of a valid payload is bad', gen.tuple(gen.array(PEER, { max_len: 10 }), gen.int(0, length(BAD_VALUES) - 1)), (p) => {
		let payload = payload_of(p[0]);
		payload[KEY_A] = BAD_VALUES[p[1]];
		assert.match(false, parse_json(payload).ok);
	});
});

describe('discovery: cache', () => {
	const PEERS = { [KEY_A]: { direct: '[2001:db8::a]:51820', handshake_age: 7 }, [KEY_B]: { direct: '[2001:db8::b]:1' } };

	it('saves and loads back the same peers', () => {
		with_context({ fs: { data: { [CACHE]: null } } }, (deps) => {
			assert.match(true, discovery.save_cache(deps.fs, CACHE, PEERS));
			assert.match(PEERS, discovery.load_cache(deps.fs, CACHE));
		});
	});

	it('writes through a temporary file and a rename', () => {
		with_context({ fs: { data: { [CACHE]: null } } }, (deps) => {
			discovery.save_cache(deps.fs, CACHE, PEERS);
			assert.match(null, deps.fs.readfile(CACHE + '.tmp'));
			assert.match(PEERS, json(deps.fs.readfile(CACHE)));
		});
	});

	it('reports a failed write', () => {
		with_context({ fs: { data: { [CACHE]: null }, behavior: { writefile: () => null } } }, (deps) => {
			assert.match(false, discovery.save_cache(deps.fs, CACHE, PEERS));
		});
	});

	it('loads a missing cache as empty', () => {
		with_context({ fs: { data: { [CACHE]: null } } }, (deps) => {
			assert.match({}, discovery.load_cache(deps.fs, CACHE));
		});
	});

	it('loads a corrupt or invalid cache as empty', () => {
		for (let body in [ '', '{', '[]', sprintf('%J', { [KEY_A]: { direct: '10.0.0.1:1' } }) ])
			with_context({ fs: { data: { [CACHE]: body } } }, (deps) => {
				assert.match({}, discovery.load_cache(deps.fs, CACHE));
			});
	});
});
