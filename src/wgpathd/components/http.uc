'use strict';

// Asynchronous HTTP GET on uclient: never a nested uloop.run(), so the daemon's loop keeps turning.

import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import { redact } from 'wgpathd.discovery';

export function create(uclient, uloop) {
	return {
		get: function(url, timeout_ms, max_bytes, cb) {
			let con = null;
			let timer = null;
			let body = '';
			let done = false;

			let finish = function(res) {
				if (done)
					return;
				done = true;
				timer.cancel();
				con.disconnect();
				cb(res);
			};
			let fail = (details) => finish(Result.err(errors.DISCOVERY_FETCH_FAILED, details));

			con = uclient.new(url, null, {
				data_read: function() {
					let chunk;
					while (!done && length(chunk = con.read())) {
						body += chunk;
						if (length(body) > max_bytes)
							fail('response too large');
					}
				},
				data_eof: () => finish(Result.ok({ status: con.status().status, body: body })),
				error: (c, code) => fail(`uclient error ${code}`),
			});
			if (!con)
				return cb(Result.err(errors.DISCOVERY_FETCH_FAILED, `invalid url ${redact(url)}`));

			// uclient's own timeout is per inactivity; the timer bounds a slowly dribbling server too.
			timer = uloop.timer(timeout_ms, () => fail('timeout'));
			con.set_timeout(timeout_ms);
			if (!con.connect() || !con.request('GET', {}))
				fail('cannot connect');
		},
	};
};
