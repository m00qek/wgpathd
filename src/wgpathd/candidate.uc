'use strict';

// Unsaved form values laid over the committed configuration: overlay() returns a
// read-only uci view that config.load and check read as if the values were committed.
//
// A candidate is { main: { <option>: value }, peers: { <network section>: { wgpathd_relay,
// wgpathd_tunnel } } }, both parts optional. Each option given replaces the committed
// one, an empty string removes it, and every option left out keeps its committed value.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import { is_name } from 'wgpathd.config';

const PARTS = [ 'main', 'peers' ];
const PEER_OPTIONS = [ 'wgpathd_relay', 'wgpathd_tunnel' ];

function invalid(details) {
	return Result.err(errors.CHECK_INVALID_CANDIDATE, details);
}

function unknown_key(obj, allowed) {
	return filter(keys(obj), (k) => !(k in allowed))[0];
}

// A number is taken as the text UCI would hold, and an empty string as a removed
// option (null); anything else is refused.
function option_value(v) {
	if (type(v) == 'string')
		return Result.ok((v == '') ? null : v);
	if (type(v) in [ 'int', 'double' ])
		return Result.ok(`${v}`);
	return null;
}

// Without `allowed`, any option name UCI accepts.
function parse_options(values, where, allowed) {
	if (type(values) != 'object')
		return invalid(`${where} must be an object`);
	let out = {};
	for (let name, v in values) {
		let known = allowed ? (name in allowed) : is_name(name);
		if (!known)
			return invalid(`${where}: unknown option '${name}'`);
		let value = option_value(v);
		if (value == null)
			return invalid(`${where}.${name} must be a string or a number`);
		out[name] = value.data;
	}
	return Result.ok(out);
}

function is_peer_section(uci, name) {
	let stype = is_name(name) ? uci.get('network', name) : null;
	return type(stype) == 'string' && index(stype, 'wireguard_') == 0;
}

// Returns the changes per package and section: { wgpathd: { main }, network: { <section> } }.
function parse(uci, candidate) {
	if (type(candidate) != 'object')
		return invalid('candidate must be an object');
	let part = unknown_key(candidate, PARTS);
	if (part != null)
		return invalid(`unknown part '${part}'`);

	let changes = { wgpathd: {}, network: {} };
	if (candidate.main != null) {
		let main = parse_options(candidate.main, 'main');
		if (!main.ok)
			return main;
		changes.wgpathd.main = main.data;
	}
	if (candidate.peers != null) {
		if (type(candidate.peers) != 'object')
			return invalid('peers must be an object');
		for (let section, values in candidate.peers) {
			if (!is_peer_section(uci, section))
				return invalid(`no wireguard peer section '${section}' in /etc/config/network`);
			let peer = parse_options(values, `peers.${section}`, PEER_OPTIONS);
			if (!peer.ok)
				return peer;
			changes.network[section] = peer.data;
		}
	}
	return Result.ok(changes);
}

function apply(section, changes) {
	let out = { ...section };
	for (let name, value in changes)
		if (value == null)
			delete out[name];
		else
			out[name] = value;
	return out;
}

export function overlay(uci, candidate) {
	let parsed = parse(uci, candidate);
	if (!parsed.ok)
		return parsed;
	let changes = parsed.data;
	let changed = (pkg, name) => changes[pkg]?.[name];

	// Only wgpathd's main can be missing from the committed config: parse() refuses
	// a peer section that does not exist.
	let section = function(pkg, name) {
		let committed = uci.get_all(pkg, name);
		let own = changed(pkg, name);
		if (own == null)
			return committed;
		return apply(committed ?? { '.name': name, '.type': 'wgpathd' }, own);
	};

	return Result.ok({
		get: function(pkg, name, opt) {
			if (opt != null)
				return section(pkg, name)?.[opt];
			return uci.get(pkg, name) ?? section(pkg, name)?.['.type'];
		},
		get_all: section,
		foreach: (pkg, stype, cb) => uci.foreach(pkg, stype, (s) => cb(apply(s, changed(pkg, s['.name']) ?? {}))),
	});
};
