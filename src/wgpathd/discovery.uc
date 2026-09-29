'use strict';

// Spoke side of discovery: R3 payload validation and the tmpfs cache.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import * as endpoint from 'wgpathd.endpoint';
import { is_pubkey } from 'wgpathd.wg';

export const MAX_BYTES = 65536;
const MAX_ENTRIES = 64;

// A url shown in a log line or the status must not carry the credentials of its user:pass@ part.
export function redact(url) {
	return (type(url) == 'string') ? replace(url, /^([a-z][a-z0-9+.-]*:\/\/)[^\/@]*@/i, '$1') : url;
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
