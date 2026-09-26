import { describe, it, prop, gen, assert, contains } from 'utest';
import { readfile } from 'fs';
import * as wg from 'wgpathd.wg';

// The shape of rpcd-mod-wireguard's `wireguard status` reply on 25.12.5.
const STATUS = json(readfile(sourcepath(0, true) + '/../../fixtures/wireguard_status.json'));
const PEER_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const PEER_C = 'ckRTxoRCqAhiHEgHPnhfpN6nU5/F2QmMe0nJ2kt7PFc=';
const PEER_D = 'hQrcvDZE8wGkiQzp3/zDaTL3dY0PfbFTcQ4r3sG1UUk=';

const KEY = gen.map(gen.string({ len: 43, charset: 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/' }), (s) => s + '=');

function reply_of(peers) {
	return { wg_mesh: { ifindex: 3, listen_port: -13716, peers: peers } };
}

function peer(endpoint, hs) {
	return { endpoint: endpoint, allowed_ips: [ '10.9.0.2/32' ], last_handshake: hs, rx_bytes: 0, tx_bytes: 0 };
}

describe('wg: commands', () => {
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

describe('wg: parse_status on a status reply', () => {
	it('returns every peer with its endpoint and handshake', () => {
		assert.match({
			[PEER_B]: { endpoint: '[fd42:7770:1::3]:51820', last_hs_ts: 1790456491 },
			[PEER_C]: { endpoint: null, last_hs_ts: null },
			[PEER_D]: { endpoint: '10.10.0.12:51820', last_hs_ts: 1790456400 },
		}, wg.parse_status(STATUS, 'wg_mesh').data);
	});

	it('keeps only endpoint and handshake per peer', () => {
		for (let key, p in wg.parse_status(STATUS, 'wg_mesh').data)
			assert.match([ 'endpoint', 'last_hs_ts' ], sort(keys(p)), key);
	});
});

describe('wg: parse_status rules', () => {
	it('returns no peers for an interface without peers', () => {
		assert.match({}, wg.parse_status(reply_of({}), 'wg_mesh').data);
	});

	it('fails when the interface is not in the reply', () => {
		for (let reply in [ null, 'x', {}, { wg_hub: STATUS.wg_mesh }, { wg_mesh: 'up' } ])
			assert.match(contains({ ok: false, error: 'WG_PARSE_FAILED', details: 'no interface wg_mesh' }),
				wg.parse_status(reply, 'wg_mesh'));
	});

	it('fails without a peer table', () => {
		assert.match(contains({ ok: false, error: 'WG_PARSE_FAILED', details: 'no peer table' }),
			wg.parse_status({ wg_mesh: { ifindex: 3 } }, 'wg_mesh'));
	});

	it('canonicalizes endpoints', () => {
		let res = wg.parse_status(reply_of({ [PEER_B]: peer('[FD42:7770:0001::3]:51820', 0) }), 'wg_mesh');
		assert.match('[fd42:7770:1::3]:51820', res.data[PEER_B].endpoint);
	});

	it('reads an endpoint it cannot canonicalize as none', () => {
		let res = wg.parse_status(reply_of({ [PEER_B]: peer('[fe80::1%eth0]:51820', 0) }), 'wg_mesh');
		assert.match(null, res.data[PEER_B].endpoint);
	});

	it('fails the whole reply on one malformed peer', () => {
		let bad = [
			{ 'not-a-key': peer(null, 0) },
			{ [PEER_B]: 'x' },
			{ [PEER_B]: peer(null, null) },
			{ [PEER_B]: peer(null, -1) },
			{ [PEER_B]: peer(null, '7') },
		];
		for (let peers in bad)
			assert.match(contains({ ok: false, error: 'WG_PARSE_FAILED', details: 'invalid peer entry' }),
				wg.parse_status(reply_of({ [PEER_C]: peer(null, 0), ...peers }), 'wg_mesh'));
	});

	prop('round-trips generated peers', gen.array(gen.tuple(KEY, gen.int(1, 65535), gen.int(0, 2000000000)), { max_len: 8 }), (peers) => {
		let want = {};
		let table = {};
		for (let p in peers) {
			let ep = `10.0.0.1:${p[1]}`;
			table[p[0]] = peer(ep, p[2]);
			want[p[0]] = { endpoint: ep, last_hs_ts: p[2] ? p[2] : null };
		}
		assert.match(want, wg.parse_status(reply_of(table), 'wg_mesh').data);
	});
});
