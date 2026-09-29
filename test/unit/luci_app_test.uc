import { describe, it, assert } from 'utest';
import { readfile, lsdir, access } from 'fs';

const LUCI  = sourcepath(0, true) + '/../../luci';
const VIEWS = LUCI + '/htdocs/luci-static/resources/view/';
const MENU  = json(readfile(LUCI + '/root/usr/share/luci/menu.d/luci-app-wgpathd.json'));
const ACL   = json(readfile(LUCI + '/root/usr/share/rpcd/acl.d/luci-app-wgpathd.json'));

function view_files() {
	return map(sort(lsdir(VIEWS + 'wgpathd')), (f) => VIEWS + 'wgpathd/' + f);
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
	it('grants the daemon status, the config check and the two UCI configs', () => {
		assert.match([ 'luci-app-wgpathd' ], keys(ACL));
		assert.match({
			read: {
				ubus: { wgpathd: [ 'status' ], 'wgpathd.config': [ 'check' ] },
				uci: [ 'wgpathd', 'network' ],
			},
			write: { uci: [ 'wgpathd', 'network' ] },
		}, { read: ACL['luci-app-wgpathd'].read, write: ACL['luci-app-wgpathd'].write });
	});

	it('covers every ubus call a view declares', () => {
		let granted = ACL['luci-app-wgpathd'].read.ubus;
		for (let file in view_files())
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
