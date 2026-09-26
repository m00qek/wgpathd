// Test double for the 'clock' component/dep (program-mode proxy; see ../luci-sso).
// TODO: implement record_call / get_behavior / get_data surface.
return {
	api: [],
	create: function(name, real, ctx) {
		let proxy = ctx.base();
		// TODO: stub the 'clock' surface
		return proxy;
	}
};
