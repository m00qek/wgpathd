'use strict';

// Unsaved form values laid over the committed configuration: overlay() returns a
// read-only uci view that config.load and check read as if the values were committed.
//
// A candidate is { main: { <option>: value }, peers: { <public key>: { relay, tunnel } } },
// both parts optional. Each option given replaces the committed one, an empty string
// removes it, and every option left out keeps its committed value. A peer given with
// neither a relay nor a tunnel left has no `peer` section, as a form that clears both
// fields removes it.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import { is_name } from 'wgpathd.config';
import { is_pubkey } from 'wgpathd.wg';

const PARTS = [ 'main', 'peers' ];
const PEER_OPTIONS = [ 'relay', 'tunnel' ];

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

// Returns the changes: { main: { <option> }, peers: { <public key>: { <option> } } }.
function parse(candidate) {
	if (type(candidate) != 'object')
		return invalid('candidate must be an object');
	let part = unknown_key(candidate, PARTS);
	if (part != null)
		return invalid(`unknown part '${part}'`);

	let changes = { main: null, peers: {} };
	if (candidate.main != null) {
		let main = parse_options(candidate.main, 'main');
		if (!main.ok)
			return main;
		changes.main = main.data;
	}
	if (candidate.peers != null) {
		if (type(candidate.peers) != 'object')
			return invalid('peers must be an object');
		for (let key, values in candidate.peers) {
			if (!is_pubkey(key))
				return invalid(`peers: '${key}' is not a WireGuard public key`);
			let peer = parse_options(values, `peers.${key}`, PEER_OPTIONS);
			if (!peer.ok)
				return peer;
			changes.peers[key] = peer.data;
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

function is_set(peer) {
	return peer.relay != null || peer.tunnel != null;
}

// The committed `peer` sections with the candidate's changes, then one for each key
// the candidate gives that has none.
function peer_sections(uci, changes) {
	let out = [];
	let taken = {};
	uci.foreach('wgpathd', 'peer', (s) => {
		let own = changes[s.public_key];
		if (own == null)
			return push(out, s);
		taken[s.public_key] = true;
		let peer = apply(s, own);
		if (is_set(peer))
			push(out, peer);
	});
	for (let key, own in changes) {
		let peer = apply({ '.type': 'peer', public_key: key }, own);
		if (!taken[key] && is_set(peer))
			push(out, peer);
	}
	return out;
}

export function overlay(uci, candidate) {
	let parsed = parse(candidate);
	if (!parsed.ok)
		return parsed;
	let changes = parsed.data;
	let main_changes = (pkg, name) => (pkg == 'wgpathd' && name == 'main') ? changes.main : null;

	// Only wgpathd's main can be missing from the committed config.
	let section = function(pkg, name) {
		let committed = uci.get_all(pkg, name);
		let own = main_changes(pkg, name);
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
		foreach: function(pkg, stype, cb) {
			if (pkg != 'wgpathd' || stype != 'peer')
				return uci.foreach(pkg, stype, cb);
			for (let s in peer_sections(uci, changes.peers))
				cb(s);
		},
	});
};
