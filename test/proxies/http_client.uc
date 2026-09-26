// Program-mode proxy (loaded via require), so it returns instead of exporting.
// data: { <url>: { status, body } | { error } }; an object body is sent as JSON.
function ok(data)           { return { ok: true,  data: data }; }
function err(code, details) { return { ok: false, error: code, details: details }; }

return {
	api: ['get'],

	create: function(name, real, ctx) {
		let proxy = ctx.base();

		function respond(url) {
			let entry = ctx.get_data(url);
			if (entry == null) {
				if (ctx.is_strict()) die("strict http mock: unmocked URL: " + url);
				return err("HTTP_REQUEST_FAILED", "HTTP_NOT_FOUND");
			}
			if (entry.error)
				return err("HTTP_REQUEST_FAILED", entry.error);
			let body = (type(entry.body) == "object") ? sprintf("%J", entry.body) : (entry.body || "");
			return ok({ status: entry.status || 200, body: body });
		}

		proxy.create = function() { return proxy; };

		proxy.get = function(url, opts) {
			ctx.record_call('get', [url, opts]);
			let f = ctx.get_behavior('get');
			if (f) return f(url, opts);
			return respond(url);
		};

		return proxy;
	}
};
