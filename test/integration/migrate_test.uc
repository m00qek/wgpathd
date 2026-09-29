import { describe, it, assert, contains } from 'utest';
import * as uci from 'uci';
import { readfile, lsdir, mkdir, unlink } from 'fs';
import * as h from 'lib.helpers';
import * as migrate from 'wgpathd.migrate';
import * as config from 'wgpathd.config';

// The migration against real UCI files in a directory of their own.

const SPOKE_B = 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=';
const SPOKE_C = 'hQrcvDZE8wGkiQzp3/zDaTL3dY0PfbFTcQ4r3sG1UUk=';
const HUB     = 'W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=';
const PRIVATE = 'aGVsbG8gdGhpcyBpcyBub3QgYSByZWFsIGtleSEhISE=';

const MAIN = { '.type': 'wgpathd', enabled: '1', role: 'spoke', mesh_iface: 'wg_mesh', hub_iface: 'wg_hub',
	discovery: 'http://10.10.0.1:7780/peers', mode: 'steer' };

// A spoke as releases up to 4 configured it: spoke_b named, spoke_c anonymous, the hub
// without settings.
function legacy_network(extra) {
	return {
		wg_mesh: { '.type': 'interface', proto: 'wireguard', private_key: PRIVATE, listen_port: '51820' },
		wg_hub: { '.type': 'interface', proto: 'wireguard', private_key: PRIVATE },
		hub: { '.type': 'wireguard_wg_mesh', public_key: HUB, endpoint_host: '2001:db8::1', endpoint_port: '51820' },
		spoke_b: { '.type': 'wireguard_wg_mesh', public_key: SPOKE_B, allowed_ips: [ '10.20.0.12/32', '10.12.0.0/16' ],
			wgpathd_relay: '10.10.0.12:51820', wgpathd_tunnel: '10.20.0.12' },
		spoke_c: { '.type': 'wireguard_wg_mesh', '.anonymous': true, public_key: SPOKE_C,
			wgpathd_relay: '10.10.0.13:51820', wgpathd_tunnel: '10.20.0.13' },
		...(extra ?? {}),
	};
}

function setup(network, peers) {
	let wgpathd = { main: MAIN };
	for (let i = 0; i < length(peers ?? []); i++)
		wgpathd[`p${i}`] = { '.type': 'peer', '.anonymous': true, ...peers[i] };
	let dir = h.uci_dir({ network: network ?? legacy_network(), wgpathd: wgpathd });
	return { dir: dir, files: () => ({ network: readfile(`${dir}/network`), wgpathd: readfile(`${dir}/wgpathd`) }) };
}

function run(s, cursor) {
	let logs = h.logger();
	let res = migrate.run(cursor ?? uci.cursor(s.dir), logs.log);
	return { res: res, logs: logs };
}

// The `peer` sections, in order, and the options of every network section.
function settings(dir) {
	let out = [];
	uci.cursor(dir).foreach('wgpathd', 'peer', (s) => push(out, { public_key: s.public_key, relay: s.relay, tunnel: s.tunnel }));
	return out;
}

function network_options(dir) {
	let out = {};
	uci.cursor(dir).foreach('network', null, (s) => {
		out[s['.name']] = filter(keys(s), (k) => substr(k, 0, 1) != '.');
	});
	return out;
}

const MIGRATED = [
	{ public_key: SPOKE_B, relay: '10.10.0.12:51820', tunnel: '10.20.0.12' },
	{ public_key: SPOKE_C, relay: '10.10.0.13:51820', tunnel: '10.20.0.13' },
];

describe('migrate: settings kept in network', () => {
	it('moves each peer\'s options into a peer section keyed by its public key', () => {
		let s = setup();
		let r = run(s);
		assert.match([ true, 2 ], [ r.res.ok, r.res.data ]);
		assert.match(MIGRATED, settings(s.dir));
		assert.match([ [ 'notice', 'migrate: moved the settings of 2 peer(s) from /etc/config/network to /etc/config/wgpathd' ] ],
			r.logs.entries);
	});

	it('removes the two options from network and leaves every other option as it was', () => {
		let s = setup();
		let before = network_options(s.dir);
		run(s);
		let after = network_options(s.dir);
		for (let name, opts in before)
			assert.match(filter(opts, (o) => !(o in [ 'wgpathd_relay', 'wgpathd_tunnel' ])), after[name], name);
		assert.match([ PRIVATE, [ '10.20.0.12/32', '10.12.0.0/16' ] ],
			[ uci.cursor(s.dir).get('network', 'wg_mesh', 'private_key'), uci.cursor(s.dir).get('network', 'spoke_b', 'allowed_ips') ]);
	});

	it('gives a spoke the peers it steered before, with the same relays and tunnels', () => {
		let s = setup();
		let before = config.load({ uci: uci.cursor(s.dir) }).data.peers;
		run(s);
		let after = config.load({ uci: uci.cursor(s.dir) }).data;
		assert.match([ [], [ HUB, SPOKE_B, SPOKE_C ] ], [ before.managed, map(before.unmanaged, (u) => u.pubkey) ]);
		assert.match(MIGRATED, map(after.peers.managed, (p) => ({ public_key: p.pubkey, relay: p.relay, tunnel: p.tunnel })));
		assert.match([ { section: 'hub', pubkey: HUB, reason: 'not configured' } ], after.peers.unmanaged);
		assert.match([], after.leftovers);
	});

	it('writes no other file, no copy of network among them', () => {
		let s = setup();
		run(s);
		assert.match([ 'network', 'wgpathd' ], sort(lsdir(s.dir)));
	});
});

describe('migrate: run again, or over settings already moved', () => {
	it('does nothing and writes nothing when there is nothing to move', () => {
		let s = setup();
		run(s);
		let files = s.files();
		let r = run(s);
		assert.match([ true, 0, [] ], [ r.res.ok, r.res.data, r.logs.entries ]);
		assert.match(files, s.files());
	});

	it('does nothing on a fresh configuration', () => {
		let s = setup({ wg_mesh: { '.type': 'interface', proto: 'wireguard' } }, []);
		let files = s.files();
		assert.match([ true, 0 ], [ run(s).res.ok, run(s).res.data ]);
		assert.match(files, s.files());
	});

	it('completes the section a peer already has, and never adds a second one', () => {
		let s = setup(null, [ { public_key: SPOKE_B, relay: '10.10.0.12:51820' } ]);
		run(s);
		assert.match(MIGRATED, settings(s.dir));
	});

	it('keeps a value wgpathd already holds, drops the one from network and says so', () => {
		let s = setup(null, [ { public_key: SPOKE_B, relay: '10.10.0.99:51820', tunnel: '10.20.0.12' } ]);
		let r = run(s);
		assert.match(true, r.res.ok);
		assert.match([ { public_key: SPOKE_B, relay: '10.10.0.99:51820', tunnel: '10.20.0.12' }, MIGRATED[1] ], settings(s.dir));
		assert.match([ [ 'warning', "migrate: network section spoke_b: kept relay '10.10.0.99:51820' of /etc/config/wgpathd, " +
			"dropped wgpathd_relay '10.10.0.12:51820'" ] ], r.logs.matching(/kept/));
		assert.match(false, 'wgpathd_relay' in network_options(s.dir).spoke_b);
	});

	it('says nothing of a value both files hold alike, a list included', () => {
		let network = legacy_network({ spoke_b: { '.type': 'wireguard_wg_mesh', public_key: SPOKE_B, wgpathd_tunnel: [ '10.20.0.12' ] } });
		let s = setup(network, [ { public_key: SPOKE_B, tunnel: [ '10.20.0.12' ] }, MIGRATED[1] ]);
		let r = run(s);
		assert.match([ true, [] ], [ r.res.ok, r.logs.matching(/kept/) ]);
	});

	it('moves a peer with one option alone, and a peer whose settings were half moved', () => {
		let network = legacy_network({ spoke_b: { '.type': 'wireguard_wg_mesh', public_key: SPOKE_B, wgpathd_tunnel: '10.20.0.12' } });
		let s = setup(network, [ { public_key: SPOKE_C, tunnel: '10.20.0.13' } ]);
		run(s);
		assert.match([ { public_key: SPOKE_C, relay: '10.10.0.13:51820', tunnel: '10.20.0.13' },
			{ public_key: SPOKE_B, relay: null, tunnel: '10.20.0.12' } ], settings(s.dir));
	});
});

describe('migrate: what it leaves alone', () => {
	it('keeps the options of a section without a valid public key, and moves the others', () => {
		let s = setup(legacy_network({ broken: { '.type': 'wireguard_wg_mesh', public_key: 'nope', wgpathd_relay: '10.0.0.1:1' } }));
		let r = run(s);
		assert.match([ true, 2 ], [ r.res.ok, r.res.data ]);
		assert.match([ [ 'warning', 'migrate: network section broken has no valid public_key, its options stay' ] ],
			r.logs.matching(/stay/));
		assert.match('10.0.0.1:1', uci.cursor(s.dir).get('network', 'broken', 'wgpathd_relay'));
	});

	it('moves nothing from a section that is not a WireGuard peer', () => {
		let s = setup({ lan: { '.type': 'interface', proto: 'static', wgpathd_relay: '10.0.0.1:1' } });
		let files = s.files();
		assert.match([ true, 0 ], [ run(s).res.ok, run(s).res.data ]);
		assert.match(files, s.files());
	});
});

describe('migrate: failures change nothing in network', () => {
	// A real cursor whose commit of `pkg` fails, as a full or read-only disk would.
	function failing_commit(dir, pkg) {
		let c = uci.cursor(dir);
		return {
			foreach: (...a) => c.foreach(...a), get: (...a) => c.get(...a), add: (...a) => c.add(...a),
			set: (...a) => c.set(...a), delete: (...a) => c.delete(...a), error: () => 'Permission denied',
			commit: (p) => (p == pkg) ? false : c.commit(p),
		};
	}

	it('fails without touching network when /etc/config/wgpathd cannot be read', () => {
		let s = setup();
		let network = s.files().network;
		unlink(`${s.dir}/wgpathd`);
		mkdir(`${s.dir}/wgpathd`);
		let r = run(s);
		assert.match(contains({ ok: false, error: 'MIGRATE_FAILED' }), r.res);
		assert.match(network, readfile(`${s.dir}/network`));
	});

	it('fails without touching either file when wgpathd cannot be written', () => {
		let s = setup();
		let files = s.files();
		let r = run(s, failing_commit(s.dir, 'wgpathd'));
		assert.match({ ok: false, error: 'MIGRATE_FAILED', details: 'cannot write /etc/config/wgpathd: Permission denied' }, { ...r.res });
		assert.match(files, s.files());
	});

	it('keeps network when it cannot be written, and the next run finishes the job', () => {
		let s = setup();
		let network = s.files().network;
		let r = run(s, failing_commit(s.dir, 'network'));
		assert.match(contains({ ok: false, details: 'cannot write /etc/config/network: Permission denied' }), r.res);
		assert.match([ network, MIGRATED ], [ readfile(`${s.dir}/network`), settings(s.dir) ]);

		r = run(s);
		assert.match([ true, 2 ], [ r.res.ok, r.res.data ]);
		assert.match(MIGRATED, settings(s.dir));
		assert.match([], config.load({ uci: uci.cursor(s.dir) }).data.leftovers);
	});
});
