'use strict';

// Renders the `ubus call wgpathd status` reply as the text `service wgpathd status` prints.

const KEY_CHARS = 8;

export function age(secs) {
	secs = max(0, int(secs));
	if (secs < 60)
		return `${secs}s`;
	if (secs < 3600)
		return `${int(secs / 60)}m`;
	if (secs < 86400)
		return `${int(secs / 3600)}h`;
	return `${int(secs / 86400)}d`;
};

function short_key(pubkey) {
	return (type(pubkey) == 'string') ? substr(pubkey, 0, KEY_CHARS) : '-';
}

function pad(s, width) {
	return sprintf(`%-${width}s`, s);
}

// Aligns columns; each row is an array of strings.
function table(rows) {
	let widths = [];
	for (let row in rows)
		for (let i = 0; i < length(row); i++)
			widths[i] = max(widths[i] ?? 0, length(row[i]));
	return map(rows, (row) => {
		let cells = map(row, (cell, i) => (i < length(row) - 1) ? pad(cell, widths[i]) : cell);
		return '  ' + join('  ', cells);
	});
}

function section(title, rows) {
	return length(rows) ? [ `${title}:`, ...table(rows) ] : [ `${title}: none` ];
}

function discovery_line(disc, now) {
	let last = (disc?.last_ok != null) ? `last success ${age(now - disc.last_ok)} ago` : 'never succeeded';
	return `discovery: ${disc?.fresh ? 'fresh' : 'stale'} (${last})`;
}

function change_text(change, now) {
	return change ? `${age(now - change.ts)} ago (${change.reason})` : 'no change yet';
}

function switches_text(n) {
	return (n == 1) ? '1 switch' : `${n ?? 0} switches`;
}

function by_section(a, b) {
	let x = a.section ?? '', y = b.section ?? '';
	return (x < y) ? -1 : (x > y) ? 1 : 0;
}

function spoke_lines(status, now) {
	let peers = map(keys(status.peers ?? {}), (key) => ({ ...status.peers[key], pubkey: key }));
	let peer_rows = map(sort(peers, by_section), (p) => [
		p.section ?? '-', short_key(p.pubkey), p.state, p.endpoint ?? '-',
		change_text(p.last_change, now), switches_text(p.switches),
	]);
	let unmanaged_rows = map(status.unmanaged ?? [], (u) => [ u.section ?? '-', short_key(u.pubkey), u.reason ]);
	return [
		`role: spoke (mode ${status.mode})`,
		discovery_line(status.discovery, now),
		...section('peers', peer_rows),
		...(length(unmanaged_rows) ? section('unmanaged', unmanaged_rows) : []),
	];
}

function hub_lines(status, now) {
	let rows = map(sort(keys(status.peers ?? {})), (key) => {
		let p = status.peers[key];
		let hs = (p.handshake_age != null) ? `handshake ${age(p.handshake_age)} ago` : 'no handshake';
		return [ short_key(key), p.direct, hs ];
	});
	return [ 'role: hub', ...section('published peers', rows) ];
}

export function render(status, now) {
	let lines = (status.role == 'hub') ? hub_lines(status, now) : spoke_lines(status, now);
	return join('\n', lines) + '\n';
};
