// utest config (modeled on ../luci-sso). Faking `deps` transitively controls a
// module and its whole import subgraph. See docs/how-to/developer/testing.md.
return {
	pattern: "*_test*.uc",
	lib_paths: [ "/usr/lib/ucode", ".", "unit", "../src" ],
	mocks: {
		fs:          null,
		uci:         null,
		ubus:        null,
		uloop:       null,
	},
};
