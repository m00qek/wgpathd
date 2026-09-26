// Program-mode proxy (loaded via require), so it returns instead of exporting.
// The surface is added together with the real component.
return {
	api: [],
	create: function(name, real, ctx) {
		return ctx.base();
	}
};
