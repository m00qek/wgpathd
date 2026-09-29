import { describe, it, assert } from 'utest';
import * as fs from 'fs';
import * as discovery from 'wgpathd.discovery';

// The discovery cache on the container's real filesystem, as root.
const HERE = sourcepath(0, true);
const SAVE = `${HERE}/../fixtures/save_cache.uc`;
const SRC  = `${HERE}/../../src`;

const PEERS = { 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=': { direct: '[2001:db8::a]:51820' } };

function scratch() {
	return fs.mkdtemp('/tmp/wgpathd-cache-XXXXXX');
}

function remove(dir) {
	system(`rm -rf '${dir}'`);
}

// Runs the save in a child process, whose umask the test sets.
function save_with_umask(umask, path) {
	let p = fs.popen(`umask ${umask}; ucode -L '${SRC}/*.uc' '${SAVE}' '${path}'`, 'r');
	let out = p.read('all');
	p.close();
	return json(out);
}

let mode = (path) => fs.lstat(path).mode;

describe('discovery cache: on a real filesystem', () => {
	it('creates the directory 0700 and the file 0600, under a umask of 0', () => {
		let base = scratch();
		let path = `${base}/wgpathd/cache.json`;
		assert.match({ ok: true, details: null }, save_with_umask('000', path));
		assert.match([ 0o700, 0o600 ], [ mode(`${base}/wgpathd`), mode(path) ]);
		assert.match(PEERS, discovery.load_cache(fs, path));
		remove(base);
	});

	it('writes nothing through a link planted at the temporary name', () => {
		let base = scratch();
		fs.mkdir(`${base}/wgpathd`, 0o700);
		fs.writefile(`${base}/target`, 'ORIGINAL');
		fs.symlink(`${base}/target`, `${base}/wgpathd/cache.json.tmp`);
		let res = discovery.save_cache(fs, `${base}/wgpathd/cache.json`, PEERS);
		assert.match([ false, `${base}/wgpathd/cache.json: ${base}/wgpathd/cache.json.tmp is a symbolic link` ], [ res.ok, res.details ]);
		assert.match('ORIGINAL', fs.readfile(`${base}/target`));
		remove(base);
	});

	it('refuses a directory others may write to, and reads no cache from it', () => {
		let base = scratch();
		let dir = `${base}/wgpathd`;
		fs.mkdir(dir);
		fs.writefile(`${dir}/cache.json`, sprintf('%J', PEERS));
		fs.chmod(dir, 0o777);
		assert.match(`${dir}/cache.json: ${dir} is writable by others`, discovery.save_cache(fs, `${dir}/cache.json`, {}).details);
		assert.match({}, discovery.load_cache(fs, `${dir}/cache.json`));
		assert.match(0o777, mode(dir), 'left as it was found');
		remove(base);
	});

	it('refuses a directory another user owns', () => {
		let base = scratch();
		let dir = `${base}/wgpathd`;
		fs.mkdir(dir, 0o700);
		fs.chown(dir, 1000, 1000);
		assert.match(`${dir}/cache.json: ${dir} is not owned by root`, discovery.save_cache(fs, `${dir}/cache.json`, PEERS).details);
		remove(base);
	});

	it('refuses a directory that is a link', () => {
		let base = scratch();
		fs.mkdir(`${base}/elsewhere`, 0o700);
		fs.symlink(`${base}/elsewhere`, `${base}/wgpathd`);
		let res = discovery.save_cache(fs, `${base}/wgpathd/cache.json`, PEERS);
		assert.match(`${base}/wgpathd/cache.json: ${base}/wgpathd is not a directory`, res.details);
		assert.match([], fs.lsdir(`${base}/elsewhere`));
		remove(base);
	});

	it('narrows the directory an older version created with the umask', () => {
		let base = scratch();
		fs.mkdir(`${base}/wgpathd`, 0o755);
		fs.chmod(`${base}/wgpathd`, 0o755);
		assert.match(true, discovery.save_cache(fs, `${base}/wgpathd/cache.json`, PEERS).ok);
		assert.match(0o700, mode(`${base}/wgpathd`));
		remove(base);
	});
});
