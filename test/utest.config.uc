// utest config (modeled on ../luci-sso). Faking `deps` transitively controls a
// module and its whole import subgraph. See the design record (repository layout).
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
