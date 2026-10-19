'use strict';

// ICMP echo prober on raw sockets read from the loop: one socket per address family and device.

import * as icmp from 'wgpathd.icmp';
import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import { canonical_ip } from 'wgpathd.endpoint';

const PROTOCOL = { [4]: 1, [6]: 58 };
const IP_PMTUDISC_DO = 2;
const MAX_PACKET = 65535;
const READS_PER_WAKEUP = 32;

function u16(bytes, at) {
	return (ord(bytes, at) << 8) | ord(bytes, at + 1);
}

// A reply answers a probe only on the socket that sent it, from the host probed, with
// that socket's echo id, the probe's sequence number and the very payload sent. Each
// socket draws its id and first sequence number at random, and every probe a nonce
// for its payload: what an underlay probe shows in the clear says nothing about a
// tunnel probe, and a reply that reaches the host outside the tunnel arrives on
// another socket. `random(n)` returns n random bytes.
// Probes: [ { host, size, device } ]; cb(probe, res) runs once per probe, with
// Result.ok(true) on the reply, Result.ok(false) at the timeout, or PROBE_SEND_FAILED.
export function create(socket, uloop, random) {
	let sockets = {};
	let payloads = {};

	let draw = function(n) {
		let bytes = random(n);
		if (type(bytes) != 'string' || length(bytes) != n)
			return Result.err(errors.PROBE_SEND_FAILED, 'no random bytes');
		return Result.ok(bytes);
	};

	// A raw IPv4 socket sees every ICMP packet on its device, and the unbound ICMPv6
	// one every ICMPv6 packet on the host: a flood of them must not keep the loop from
	// its timers. So a wakeup reads a bounded batch (the loop is level-triggered and
	// comes back for the rest), and only a reply that matches a probe is checksummed.
	let receive = function(fam, s) {
		for (let n = 0; n < READS_PER_WAKEUP; n++) {
			let msg = s.sock.recvmsg(MAX_PACKET);
			if (msg == null)
				return;
			let reply = icmp.parse_reply(fam, msg.data);
			if (reply == null || reply.id != s.id)
				continue;
			let key = `${canonical_ip(msg.address?.address)} ${reply.seq}`;
			let p = s.pending[key];
			if (p == null || icmp.echoed(msg.data, reply) != p.data || !icmp.intact(fam, msg.data, reply))
				continue;
			delete s.pending[key];
			p.cb(p.probe, Result.ok(true));
		}
	};

	// The kernel must not fragment a probe on its way out: a full-size probe that
	// does not fit is refused at once, which reads as not answered.
	let configure = function(sock, fam) {
		if (fam == 6)
			return sock.setopt(socket.IPPROTO_IPV6, socket.IPV6_DONTFRAG, 1);
		return sock.setopt(socket.IPPROTO_IP, socket.IP_MTU_DISCOVER, IP_PMTUDISC_DO);
	};

	// A socket stays bound to the index its device had, and netifd deletes and
	// creates an interface again on ifup: so it is bound again, by name, for every probe.
	let bind = (sock, device) => device == null || sock.setopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, device);

	let new_socket = function(fam) {
		let numbers = draw(4);
		if (!numbers.ok)
			return numbers;
		let sock = socket.create((fam == 6) ? socket.AF_INET6 : socket.AF_INET,
			socket.SOCK_RAW | socket.SOCK_NONBLOCK, PROTOCOL[fam]);
		if (!sock)
			return Result.err(errors.PROBE_SEND_FAILED, `raw socket: ${socket.error()}`);
		if (!configure(sock, fam)) {
			let e = socket.error();
			sock.close();
			return Result.err(errors.PROBE_SEND_FAILED, `raw socket: ${e}`);
		}
		let s = { sock: sock, id: u16(numbers.data, 0), seq: u16(numbers.data, 2), pending: {} };
		s.handle = uloop.handle(sock, () => receive(fam, s), uloop.ULOOP_READ);
		return Result.ok(s);
	};

	let open = function(fam, device) {
		let key = `${fam} ${device ?? ''}`;
		if (sockets[key] == null) {
			let created = new_socket(fam);
			if (!created.ok)
				return created;
			sockets[key] = created.data;
		}
		let s = sockets[key];
		if (!bind(s.sock, device))
			return Result.err(errors.PROBE_SEND_FAILED, `raw socket on ${device}: ${socket.error()}`);
		return Result.ok(s);
	};

	// Returns where the probe waits for its reply: the socket it left by and its key there.
	let transmit = function(host, fam, probe, cb) {
		let opened = open(fam, probe.device);
		if (!opened.ok)
			return opened;
		let nonce = draw(icmp.NONCE);
		if (!nonce.ok)
			return nonce;
		let s = opened.data;
		s.seq = (s.seq + 1) & 0xffff;
		let payload = icmp.with_nonce(payloads[probe.size] ??= icmp.echo_payload(probe.size), nonce.data);
		let packet = icmp.echo_request(fam, s.id, s.seq, payload.data, payload.sum);
		let addr = { family: (fam == 6) ? socket.AF_INET6 : socket.AF_INET, address: host, port: 0 };
		if (s.sock.send(packet, 0, addr) == null)
			return Result.err(errors.PROBE_SEND_FAILED, `${host}: ${socket.error()}`);
		let key = `${host} ${s.seq}`;
		s.pending[key] = { probe: probe, data: payload.data, cb: cb };
		return Result.ok({ socket: s, key: key });
	};

	return {
		send: function(probes, timeout, cb) {
			let waiting = [];
			for (let probe in probes) {
				let host = canonical_ip(probe.host);
				let fam = icmp.family(host);
				let sent = (fam != null)
					? transmit(host, fam, probe, cb)
					: Result.err(errors.PROBE_SEND_FAILED, `${probe.host}: not an IP address`);
				if (sent.ok)
					push(waiting, sent.data);
				else
					cb(probe, sent);
			}
			if (length(waiting) == 0)
				return;
			// uloop keeps a timer that has fired until it is cancelled; `this` is the timer.
			uloop.timer(int(timeout * 1000), function() {
				this.cancel();
				for (let w in waiting) {
					let p = w.socket.pending[w.key];
					if (p == null)
						continue;
					delete w.socket.pending[w.key];
					p.cb(p.probe, Result.ok(false));
				}
			});
		},
	};
};
