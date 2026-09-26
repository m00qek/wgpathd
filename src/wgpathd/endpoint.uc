'use strict';

// The one canonical endpoint form (`[v6]:port` or `v4:port`, as `wg` prints it).

function split_endpoint(s) {
	if (type(s) != 'string')
		return null;
	let m = match(s, /^\[([^\]]+)\]:([0-9]{1,5})$/);
	if (m)
		return { host: m[1], port: m[2], v6: true };
	m = match(s, /^([0-9.]+):([0-9]{1,5})$/);
	return m ? { host: m[1], port: m[2], v6: false } : null;
}

export function canonical_ip(host) {
	let arr = (type(host) == 'string') ? iptoarr(host) : null;
	return arr ? arrtoip(arr) : null;
};

export function canonical(s) {
	let parts = split_endpoint(s);
	if (parts == null)
		return null;

	let arr = iptoarr(parts.host);
	let port = +parts.port;
	if (arr == null || (length(arr) == 16) != parts.v6 || port < 1 || port > 65535)
		return null;

	let host = arrtoip(arr);
	return parts.v6 ? `[${host}]:${port}` : `${host}:${port}`;
};

export function is_v6(ep) {
	let parts = split_endpoint(canonical(ep));
	return parts != null && parts.v6;
};

export function host(ep) {
	let parts = split_endpoint(canonical(ep));
	return parts ? parts.host : null;
};
