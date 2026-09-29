import { describe, it, assert } from 'utest';
import { readfile, lsdir, access, stat } from 'fs';

const LUCI  = sourcepath(0, true) + '/../../luci';
const RESOURCES = LUCI + '/htdocs/luci-static/resources/';
const VIEWS = RESOURCES + 'view/';
const MENU  = json(readfile(LUCI + '/root/usr/share/luci/menu.d/luci-app-wgpathd.json'));
const ACL   = json(readfile(LUCI + '/root/usr/share/rpcd/acl.d/luci-app-wgpathd.json'));

function view_files() {
	return map(sort(lsdir(VIEWS + 'wgpathd')), (f) => VIEWS + 'wgpathd/' + f);
}

// Every script the app ships: views, the Overview include and the shared module.
function scripts(dir) {
	let out = [];
	for (let f in sort(lsdir(dir))) {
		let path = dir + f;
		if (stat(path).type == 'directory')
			push(out, ...scripts(path + '/'));
		else if (match(f, /\.js$/))
			push(out, path);
	}
	return out;
}

function declared_calls(file) {
	return map(match(readfile(file), /rpc\.declare\(\{[^}]*\}/g), (m) => ({
		object: match(m[0], /object: '([^']+)'/)[1],
		method: match(m[0], /method: '([^']+)'/)[1],
	}));
}

describe('luci-app-wgpathd: menu', () => {
	it('puts the live status under Status and the settings under Network', () => {
		assert.match({ 'admin/status/wgpathd': 'wgpathd/status', 'admin/network/wgpathd': 'wgpathd/settings' },
			{ 'admin/status/wgpathd': MENU['admin/status/wgpathd'].action.path,
			  'admin/network/wgpathd': MENU['admin/network/wgpathd'].action.path });
		assert.match(2, length(MENU));
	});

	it('titles both entries Mesh paths', () => {
		for (let path, entry in MENU)
			assert.match('Mesh paths', entry.title, path);
	});

	it('opens a view the package ships', () => {
		for (let path, entry in MENU) {
			assert.match('view', entry.action.type, path);
			assert.match(true, access(VIEWS + entry.action.path + '.js'), entry.action.path);
		}
	});

	it('shows each entry only to sessions granted the app ACL', () => {
		for (let path, entry in MENU)
			assert.match([ 'luci-app-wgpathd' ], entry.depends.acl, path);
	});
});

describe('luci-app-wgpathd: ACL', () => {
	// /etc/config/network holds every WireGuard private key of the router: the peers
	// method lists what the pages need of it.
	it('grants the daemon status, the config methods and wgpathd\'s own UCI config, never network', () => {
		assert.match([ 'luci-app-wgpathd' ], keys(ACL));
		assert.match({
			read: {
				ubus: { wgpathd: [ 'status' ], 'wgpathd.config': [ 'check', 'peers', 'schema' ] },
				uci: [ 'wgpathd' ],
			},
			write: { uci: [ 'wgpathd' ] },
		}, { read: ACL['luci-app-wgpathd'].read, write: ACL['luci-app-wgpathd'].write });
	});

	it('grants no network, file, exec or wildcard access', () => {
		assert.match(null, match(readfile(LUCI + '/root/usr/share/rpcd/acl.d/luci-app-wgpathd.json'), /network|file|exec|\*/));
	});

	it('covers every ubus call a script declares', () => {
		let granted = ACL['luci-app-wgpathd'].read.ubus;
		let files = scripts(RESOURCES);
		assert.match(true, length(filter(files, (f) => length(declared_calls(f)) > 0)) > 0, 'some script declares a call');
		for (let file in files)
			for (let call in declared_calls(file))
				assert.match(true, call.method in granted[call.object], `${file}: ${call.object}.${call.method}`);
	});
});

describe('luci-app-wgpathd: views', () => {
	it('each is a strict-mode LuCI view', () => {
		for (let file in view_files()) {
			let src = readfile(file);
			assert.match(0, index(src, "'use strict';\n"), file);
			assert.match(true, index(src, "\nreturn view.extend({") > 0, file);
		}
	});
});

describe('luci-app-wgpathd: shared module and Overview include', () => {
	it('ships the shared module and one Status → Overview include', () => {
		assert.match([ RESOURCES + 'view/status/include/70_wgpathd.js', RESOURCES + 'view/wgpathd/settings.js',
			RESOURCES + 'view/wgpathd/status.js', RESOURCES + 'wgpathd.js' ], sort(scripts(RESOURCES)));
	});

	it('each is a strict-mode LuCI class', () => {
		for (let file in [ RESOURCES + 'wgpathd.js', RESOURCES + 'view/status/include/70_wgpathd.js' ]) {
			let src = readfile(file);
			assert.match(0, index(src, "'use strict';\n"), file);
			assert.match(true, index(src, "\nreturn baseclass.extend({") > 0, file);
		}
	});
});
