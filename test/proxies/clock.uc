// Program-mode proxy (loaded via require), so it returns instead of exporting.
return {
	api: ['now'],

	create: function(name, real, ctx) {
		let proxy = ctx.base();

		proxy.create = function() { return proxy; };

		proxy.now = function() {
			ctx.record_call('now', []);
			let f = ctx.get_behavior('now');
			if (f) return f();
			return ctx.get_data('now') ?? 0;
		};

		return proxy;
	}
};
