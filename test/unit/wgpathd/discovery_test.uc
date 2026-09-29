import { describe, it, prop, gen, assert, contains } from 'utest';
import * as h from 'lib.helpers';
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
	const DIR = '/var/run/wgpathd';

	it('saves and loads back the same peers', () => {
		let fs = h.fs({});
		assert.match(contains({ ok: true }), discovery.save_cache(fs, CACHE, PEERS));
		assert.match(PEERS, discovery.load_cache(fs, CACHE));
	});

	it('writes through a new temporary file and a rename, with modes 0700 and 0600', () => {
		let fs = h.fs({ [CACHE + '.tmp']: 'stale' });
		discovery.save_cache(fs, CACHE, PEERS);
		assert.match(null, fs.readfile(CACHE + '.tmp'));
		assert.match(PEERS, json(fs.readfile(CACHE)));
		assert.match([ 0o700, 0o600 ], [ fs.lstat(DIR).mode, fs.lstat(CACHE).mode ]);
	});

	it('takes back a directory an older version left readable by others', () => {
		let fs = h.fs({});
		fs.dirs[DIR] = { uid: 0, mode: 0o755 };
		assert.match(contains({ ok: true }), discovery.save_cache(fs, CACHE, PEERS));
		assert.match(0o700, fs.lstat(DIR).mode);
	});

	it('refuses a directory another user owns or may write to, or that is not one', () => {
		let cases = [
			[ { uid: 1000, mode: 0o700 }, `${DIR} is not owned by root` ],
			[ { uid: 0, mode: 0o777 }, `${DIR} is writable by others` ],
			[ { uid: 0, mode: 0o770 }, `${DIR} is writable by others` ],
		];
		for (let c in cases) {
			let fs = h.fs({ [CACHE]: sprintf('%J', PEERS) });
			fs.dirs[DIR] = c[0];
			assert.match(contains({ ok: false, error: 'CACHE_SAVE_FAILED', details: `${CACHE}: ${c[1]}` }),
				discovery.save_cache(fs, CACHE, {}), c[1]);
			assert.match({}, discovery.load_cache(fs, CACHE), c[1]);
		}
		let fs = h.fs({});
		fs.links[DIR] = '/tmp';
		assert.match(contains({ ok: false, details: `${CACHE}: ${DIR} is not a directory` }), discovery.save_cache(fs, CACHE, PEERS));
	});

	it('refuses to write through a link at the temporary name, and leaves it be', () => {
		let fs = h.fs({});
		fs.links[CACHE + '.tmp'] = '/etc/shadow';
		assert.match(contains({ ok: false, error: 'CACHE_SAVE_FAILED', details: `${CACHE}: ${CACHE}.tmp is a symbolic link` }),
			discovery.save_cache(fs, CACHE, PEERS));
		assert.match([ '/etc/shadow', null ], [ fs.links[CACHE + '.tmp'], fs.readfile(CACHE) ]);
	});

	it('reports a failed write', () => {
		let fs = h.fs({});
		fs.open = () => null;
		assert.match(contains({ ok: false, error: 'CACHE_SAVE_FAILED', details: `${CACHE}: ${CACHE}.tmp: Operation not permitted` }),
			discovery.save_cache(fs, CACHE, PEERS));
	});

	it('loads a missing cache as empty', () => {
		assert.match({}, discovery.load_cache(h.fs({}), CACHE));
	});

	it('loads a corrupt or invalid cache as empty', () => {
		for (let body in [ '', '{', '[]', sprintf('%J', { [KEY_A]: { direct: '10.0.0.1:1' } }) ])
			assert.match({}, discovery.load_cache(h.fs({ [CACHE]: body }), CACHE), body);
	});

	it('does not read a cache through a link', () => {
		let fs = h.fs({ '/tmp/planted.json': sprintf('%J', PEERS) });
		fs.dirs[DIR] = { uid: 0, mode: 0o700 };
		fs.links[CACHE] = '/tmp/planted.json';
		fs.readfile = (path) => (path == CACHE) ? fs.files['/tmp/planted.json'] : null;
		assert.match({}, discovery.load_cache(fs, CACHE));
	});
});

describe('discovery: redact', () => {
	it('drops the user:pass@ part of a url and leaves the rest of a plain url alone', () => {
		let cases = {
			'http://wgpathd:secret@10.10.0.1:7780/peers': 'http://10.10.0.1:7780/peers',
			'https://user@[2001:db8::1]:7780/peers': 'https://[2001:db8::1]:7780/peers',
			'http://10.10.0.1:7780/peers': 'http://10.10.0.1:7780/peers',
			'http://10.10.0.1:7780/a@b': 'http://10.10.0.1:7780/a@b',
			'http://[2001:db8::1]:7780/peers': 'http://[2001:db8::1]:7780/peers',
			'http://hub.example.org': 'http://hub.example.org',
		};
		for (let url, shown in cases)
			assert.match(shown, discovery.redact(url), url);
	});

	// The cases of the 2026-09-29 audit.
	it('keeps no part of the credentials, a query or a fragment', () => {
		let cases = {
			'http://user:p@ss@h/peers': 'http://h/peers',
			'http://u:p@ss@[2001:db8::1]:7780/peers': 'http://[2001:db8::1]:7780/peers',
			'HTTP://u:p@h/': 'HTTP://h/',
			'hTtP://a:b@c': 'hTtP://c',
			'http://h/peers?token=secret': 'http://h/peers',
			'http://host/peers?u=a@b': 'http://host/peers',
			'http://h/peers#secret': 'http://h/peers',
			'http://user:p%40ss@host/x': 'http://host/x',
			'http://u:p@h/a@b': 'http://h/a@b',
		};
		for (let url, shown in cases)
			assert.match(shown, discovery.redact(url), url);
	});

	it('shows a placeholder for what does not read as scheme://host', () => {
		for (let url in [ ' http://u:p@h/', 'u:p@h/peers', '//u:p@h/x', 'http://u:p/a@h/peers', 'http://user:pa?ss@host/x',
			'http://user:pa#ss@host/x', 'http://user:pass@host/peers\nhttp://u2:p2@h', 'http://[10.0.0.1]/', 'http://[fe80::1%eth0]/',
			'http://h:p/', 'http://', 'http:///peers', 'secret', '', null, 7 ])
			assert.match('(unreadable url)', discovery.redact(url), url);
	});
});

describe('discovery: parse_url', () => {
	it('splits a url into what may be shown', () => {
		assert.match({ scheme: 'http', authority: '10.10.0.1:7780', host: '10.10.0.1', port: '7780', path: '/peers' },
			discovery.parse_url('http://u:p@10.10.0.1:7780/peers?x#y'));
		assert.match({ scheme: 'http', authority: '[2001:db8::1]', host: '2001:db8::1', port: null, path: '' },
			discovery.parse_url('http://[2001:db8::1]'));
		assert.match(contains({ host: 'hub.example.org', port: null, path: '/' }), discovery.parse_url('http://hub.example.org/'));
	});
});
