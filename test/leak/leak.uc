// Memory each component keeps per use, on the real uloop: the prober against
// loopback, a discovery fetch against the publisher, and a command. uloop keeps
// a timer that has fired until it is cancelled, and a callback that captures its
// own timer, process or connection is never freed: either shows up here as bytes
// kept per use, and the daemon repeats each use thousands of times a day.
// Runs in the openwrt container (make leak, devenv/scripts/leak.sh); it needs raw
// sockets for the prober.
import * as uloop from 'uloop';
import * as socket from 'socket';
import * as uclient from 'uclient';
import * as fs from 'fs';
import * as icmp from 'wgpathd.components.icmp';
import * as http from 'wgpathd.components.http';
import * as exec from 'wgpathd.components.exec';
import * as publisher from 'wgpathd.publisher';
import { random_source } from 'wgpathd.deps';

const WARM = 300;
const LIMIT = 64;
const PORT = 17780;

function rss() {
	return +match(fs.readfile('/proc/self/status'), /VmRSS:\s+(\d+)/)[1];
}

let prober = icmp.create(socket, uloop, random_source(fs));
let client = http.create(uclient, uloop);
let run = exec.create(uloop);
let server = null;

// Each use calls done() when it is over.
const USES = {
	probe: {
		times: 2000,
		use: function(done) {
			let left = 2;
			prober.send([ { host: '127.0.0.1', size: 1200, device: null }, { host: '::1', size: 1200, device: null } ],
				0.02, () => { if (--left == 0) done(); });
		},
	},
	fetch: {
		times: 2000,
		use: (done) => client.get(`http://127.0.0.1:${PORT}/peers`, 1000, 65536, done),
	},
	exec: {
		times: 1000,
		use: (done) => run([ 'true' ], 5, done),
	},
};

function measure(name, cb) {
	let u = USES[name];
	let n = 0, base = null;
	function step() {
		if (n == WARM)
			base = rss();
		if (n++ < u.times)
			return u.use(() => uloop.timer(0, function() { this.cancel(); step(); }));
		cb((rss() - base) * 1024 / (u.times - WARM));
	}
	step();
}

uloop.init();
let listening = publisher.listen({ socket: socket, uloop: uloop }, '127.0.0.1', PORT, () => ({ a: { endpoint: '[2001:db8::1]:51820' } }));
if (!listening.ok)
	die(`publisher: ${listening.code}`);

let failed = [];
let names = keys(USES);
function next(i) {
	if (i == length(names))
		return uloop.end();
	measure(names[i], (bytes) => {
		printf("%-6s %6.0f bytes kept per use\n", names[i], bytes);
		if (bytes > LIMIT)
			push(failed, names[i]);
		next(i + 1);
	});
}
uloop.timer(0, function() { this.cancel(); next(0); });
uloop.run();
listening.data.close();

if (length(failed)) {
	printf("over %d bytes per use: %s\n", LIMIT, join(' ', failed));
	exit(1);
}
