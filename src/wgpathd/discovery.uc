'use strict';

// Spoke side of discovery: R3 payload validation and the tmpfs cache.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import * as endpoint from 'wgpathd.endpoint';
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

// One bad entry rejects the whole payload, so a buggy or lying hub is DoS-only.
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
		peers[key] = entry;
	}
	return Result.ok(peers);
};

// The cache holds a parsed payload and is re-validated on load; any problem is an empty cache.
export function load_cache(fs, path) {
	let res = parse(fs.readfile(path));
	return res.ok ? res.data : {};
};

export function save_cache(fs, path, peers) {
	let tmp = path + '.tmp';
	fs.mkdir(replace(path, /\/[^\/]*$/, ''));
	return fs.writefile(tmp, sprintf('%J', peers)) != null && fs.rename(tmp, path) == true;
};
