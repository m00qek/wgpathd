// Test double for the 'http_client' component/dep (program-mode proxy; see ../luci-sso).
// TODO: implement record_call / get_behavior / get_data surface.
return {
	api: [],
	create: function(name, real, ctx) {
		let proxy = ctx.base();
		// TODO: stub the 'http_client' surface
		return proxy;
	}
};
