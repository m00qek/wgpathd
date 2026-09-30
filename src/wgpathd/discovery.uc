'use strict';

// Spoke side of discovery: payload validation and the tmpfs cache.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import * as endpoint from 'wgpathd.endpoint';
import * as address from 'wgpathd.address';
import { is_pubkey } from 'wgpathd.wg';

export const MAX_BYTES = 65536;
const MAX_ENTRIES = 64;

export const UNREADABLE_URL = '(unreadable url)';

// Reads scheme://[userinfo@]host[:port][path][?query][#fragment] into what may be shown:
// { scheme, authority: host[:port], host, port, path }, or null for anything else. The
// authority ends at the first /, ? or #, and its userinfo at the last @ within it.
export function parse_url(url) {
	let m = (type(url) == 'string') ? match(url, /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^\/?#]*)([^?#]*)/) : null;
	if (m == null || match(m[3], /^[!-~]*$/) == null)
		return null;
	let authority = replace(m[2], /^.*@/, '');
	let h = match(authority, /^(\[([0-9A-Fa-f:.]+)\]|[A-Za-z0-9.-]+)(:([0-9]+))?$/);
	if (h == null || (h[2] != null && length(iptoarr(h[2]) ?? []) != 16))
		return null;
	return { scheme: m[1], authority: authority, host: h[2] ?? h[1], port: h[4], path: m[3] };
};

// A url shown in a log line or the status keeps neither its credentials nor its query
// and fragment, and what does not read as a url is not shown at all.
export function redact(url) {
	let u = parse_url(url);
	return u ? `${u.scheme}://${u.authority}${u.path}` : UNREADABLE_URL;
};

function decode(stdout) {
	if (type(stdout) != 'string' || length(stdout) > MAX_BYTES)
		return null;
	try {
		return json(stdout);
	}
	catch (e) {
		return null;
	}
}

function parse_entry(value) {
	if (type(value) != 'object')
		return null;
	let direct = endpoint.canonical(value.direct);
	if (!endpoint.is_v6(direct))
		return null;
	if (!exists(value, 'handshake_age'))
		return { direct: direct };
	let age = value.handshake_age;
	return (type(age) == 'int' && age >= 0) ? { direct: direct, handshake_age: age } : null;
}

// One malformed entry rejects the whole payload, so a buggy or lying hub is DoS-only.
// A well-formed entry whose address can be no direct path, such as loopback or
// link-local, is left out alone: it is one peer's address, not a broken payload.
export function parse(stdout) {
	let payload = decode(stdout);
	if (type(payload) != 'object')
		return Result.err(errors.DISCOVERY_INVALID_JSON);
	if (length(payload) > MAX_ENTRIES)
		return Result.err(errors.DISCOVERY_INVALID_PEERS, 'too many peers');

	let peers = {};
	for (let key, value in payload) {
		if (!is_pubkey(key))
			return Result.err(errors.DISCOVERY_INVALID_PEERS, 'invalid public key');
		let entry = parse_entry(value);
		if (entry == null)
			return Result.err(errors.DISCOVERY_INVALID_PEERS, key);
		if (address.can_be_direct(endpoint.host(entry.direct)))
			peers[key] = entry;
	}
	return Result.ok(peers);
};

function directory(path) {
	return replace(path, /\/[^\/]*$/, '');
}

// Anyone else who can write to the cache's directory could plant a cache, or a link
// that makes the daemon write where it points, as root.
function unsafe_directory(fs, dir) {
	let st = fs.lstat(dir);
	if (st?.type != 'directory')
		return `${dir} is not a directory`;
	if (st.uid != 0)
		return `${dir} is not owned by root`;
	if (st.mode & 0o022)
		return `${dir} is writable by others`;
	return null;
}

// The cache holds a parsed payload and is re-validated on load; any problem is an empty cache.
export function load_cache(fs, path) {
	if (unsafe_directory(fs, directory(path)) != null || fs.lstat(path)?.type != 'file')
		return {};
	let res = parse(fs.readfile(path));
	return res.ok ? res.data : {};
};

// Written to a new file, which open's `x` never lets be a link, then renamed over the
// cache; the modes are set outright, whatever the umask.
export function save_cache(fs, path, peers) {
	let fail = (why) => Result.err(errors.CACHE_SAVE_FAILED, `${path}: ${why}`);
	let dir = directory(path);
	let tmp = path + '.tmp';
	fs.mkdir(dir, 0o700);
	let unsafe = unsafe_directory(fs, dir);
	if (unsafe != null)
		return fail(unsafe);
	if (!fs.chmod(dir, 0o700))
		return fail(`chmod ${dir}: ${fs.error()}`);
	let stale = fs.lstat(tmp);
	if (stale?.type == 'link')
		return fail(`${tmp} is a symbolic link`);
	if (stale != null)
		fs.unlink(tmp);

	let file = fs.open(tmp, 'wx', 0o600);
	if (file == null)
		return fail(`${tmp}: ${fs.error()}`);
	let written = file.write(sprintf('%J', peers)) != null;
	file.close();
	if (!written || !fs.chmod(tmp, 0o600) || !fs.rename(tmp, path)) {
		let e = fs.error() ?? 'not written';
		fs.unlink(tmp);
		return fail(e);
	}
	return Result.ok();
};
