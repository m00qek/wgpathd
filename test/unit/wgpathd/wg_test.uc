import { describe, it, prop, gen, assert, contains } from 'utest';
import { readfile } from 'fs';
import * as wg from 'wgpathd.wg';

// Captured from real WireGuard (two 25.12.5 containers); the keys are throwaway.
const DUMP        = readfile(sourcepath(0, true) + '/../../fixtures/wg_show_dump.txt');
const PRIVATE_KEY = split(DUMP, '\t')[0];
const PEER_B      = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const PEER_C      = 'ckRTxoRCqAhiHEgHPnhfpN6nU5/F2QmMe0nJ2kt7PFc=';

const IFACE_LINE = 'PRIVATEKEYPLACEHOLDERxxxxxxxxxxxxxxxxxxxxxx=\tW+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=\t51820\toff';
const KEY        = gen.map(gen.string({ len: 43, charset: 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/' }), (s) => s + '=');

function peer_line(key, ep, hs) {
	return join('\t', [ key, '(none)', ep, '10.9.0.2/32', hs, '0', '0', 'off' ]);
}

function dump_of(...peer_lines) {
	return join('\n', [ IFACE_LINE, ...peer_lines ]) + '\n';
}

describe('wg: commands', () => {
	it('reads the interface with wg show dump', () => {
		assert.match([ 'wg', 'show', 'wg_mesh', 'dump' ], wg.dump_command('wg_mesh'));
	});

	it('sets only the endpoint of one peer', () => {
		assert.match([ 'wg', 'set', 'wg_mesh', 'peer', PEER_B, 'endpoint', '10.10.0.12:51820' ],
			wg.set_endpoint_command('wg_mesh', PEER_B, '10.10.0.12:51820'));
	});
});

describe('wg: is_pubkey', () => {
	it('accepts 44 base64 characters ending in =', () => {
		assert.match(true, wg.is_pubkey(PEER_B));
	});

	it('rejects anything else', () => {
		for (let v in [ null, '', substr(PEER_B, 1), PEER_B + '=', replace(PEER_B, '=', 'A'),
			replace(PEER_B, 'O', '-'), ' ' + substr(PEER_B, 1), 42 ])
			assert.match(false, wg.is_pubkey(v));
	});
});

describe('wg: parse_dump on a real dump', () => {
	it('returns every peer with its endpoint and handshake', () => {
		assert.match({
			[PEER_B]: { endpoint: '[fd42:7770:1::3]:51820', last_hs_ts: 1790456491 },
			[PEER_C]: { endpoint: null, last_hs_ts: null },
		}, wg.parse_dump(DUMP).data);
	});

	it('never carries the private key into the result', () => {
		assert.match(44, length(PRIVATE_KEY));
		let text = sprintf('%J', wg.parse_dump(DUMP));
		assert.match(-1, index(text, PRIVATE_KEY));
	});

	it('keeps only endpoint and handshake per peer', () => {
		for (let key, peer in wg.parse_dump(DUMP).data)
			assert.match([ 'endpoint', 'last_hs_ts' ], sort(keys(peer)), key);
	});
});

describe('wg: parse_dump rules', () => {
	it('returns no peers for an interface without peers', () => {
		assert.match({}, wg.parse_dump(IFACE_LINE + '\n').data);
	});

	it('canonicalizes endpoints', () => {
		let res = wg.parse_dump(dump_of(peer_line(PEER_B, '[FD42:7770:0001::3]:51820', '0')));
		assert.match('[fd42:7770:1::3]:51820', res.data[PEER_B].endpoint);
	});

	it('reads an endpoint it cannot canonicalize as none', () => {
		let res = wg.parse_dump(dump_of(peer_line(PEER_B, '[fe80::1%eth0]:51820', '0')));
		assert.match(null, res.data[PEER_B].endpoint);
	});

	it('fails on empty or missing output', () => {
		for (let v in [ null, '', '\n' ])
			assert.match(contains({ ok: false, error: 'WG_PARSE_FAILED' }), wg.parse_dump(v));
	});

	it('fails on a malformed peer line and names only its line number', () => {
		let bad = [
			join('\t', [ PEER_B, '(none)', '(none)', '10.9.0.2/32', '0', '0', '0' ]),
			peer_line('not-a-key', '(none)', '0'),
			peer_line(PEER_B, '(none)', 'never'),
			peer_line(PEER_B, '(none)', '-1'),
		];
		for (let line in bad) {
			let res = wg.parse_dump(dump_of(peer_line(PEER_C, '(none)', '0'), line));
			assert.match(false, res.ok, line);
			assert.match('WG_PARSE_FAILED', res.error);
			assert.match('line 3', res.details);
		}
	});

	it('never echoes the interface line in an error', () => {
		let res = wg.parse_dump(IFACE_LINE + '\ngarbage\n');
		assert.match(-1, index(sprintf('%J', res), 'yHUjYBBk'));
	});

	prop('round-trips generated peers', gen.array(gen.tuple(KEY, gen.int(1, 65535), gen.int(0, 2000000000)), { max_len: 8 }), (peers) => {
		let want = {};
		let lines = [];
		for (let p in peers) {
			let ep = `10.0.0.1:${p[1]}`;
			push(lines, peer_line(p[0], ep, `${p[2]}`));
			want[p[0]] = { endpoint: ep, last_hs_ts: p[2] ? p[2] : null };
		}
		assert.match(want, wg.parse_dump(dump_of(...lines)).data);
	});

	prop('rejects the whole dump for one line with the wrong field count', gen.int(1, 12), (n) => {
		if (n == 8)
			return;
		let fields = [];
		for (let i = 0; i < n; i++)
			push(fields, i ? '0' : PEER_B);
		let res = wg.parse_dump(dump_of(peer_line(PEER_C, '(none)', '0'), join('\t', fields)));
		assert.match(false, res.ok);
	});
});
