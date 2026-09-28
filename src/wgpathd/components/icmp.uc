'use strict';

// ICMP echo prober on raw sockets read from the loop: one socket per address family and device.

import * as icmp from 'wgpathd.icmp';
import * as Result from 'wgpathd.result';
import * as errors from 'wgpathd.errors';
import { canonical_ip } from 'wgpathd.endpoint';

const PROTOCOL = { [4]: 1, [6]: 58 };
const IP_PMTUDISC_DO = 2;
const MAX_PACKET = 65535;

// `id` marks this daemon's echoes; every probe takes the next sequence number, so a
// reply to a probe that already timed out, or to anyone else's ping, never matches.
// Probes: [ { host, size, device } ]; cb(probe, res) runs once per probe, with
// Result.ok(true) on the reply, Result.ok(false) at the timeout, or PROBE_SEND_FAILED.
export function create(socket, uloop, id) {
	let sockets = {};
	let pending = {};
	let seq = 0;

	let receive = function(fam, sock) {
		let msg;
		while ((msg = sock.recvmsg(MAX_PACKET)) != null) {
			let reply = icmp.parse_reply(fam, msg.data);
			if (reply == null || reply.id != id)
				continue;
			let key = `${canonical_ip(msg.address?.address)} ${reply.seq}`;
			let p = pending[key];
			if (p == null || p.size != reply.size)
				continue;
			delete pending[key];
			p.cb(p.probe, Result.ok(true));
		}
	};

	// The kernel must not fragment a probe on its way out: a full-size probe that
	// does not fit is refused at once, which reads as not answered.
	let configure = function(sock, fam, device) {
		if (device != null && !sock.setopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, device))
			return false;
		if (fam == 6)
			return sock.setopt(socket.IPPROTO_IPV6, socket.IPV6_DONTFRAG, 1);
		return sock.setopt(socket.IPPROTO_IP, socket.IP_MTU_DISCOVER, IP_PMTUDISC_DO);
	};

	let open = function(fam, device) {
		let key = `${fam} ${device ?? ''}`;
		if (sockets[key])
			return Result.ok(sockets[key].sock);
		let sock = socket.create((fam == 6) ? socket.AF_INET6 : socket.AF_INET,
			socket.SOCK_RAW | socket.SOCK_NONBLOCK, PROTOCOL[fam]);
		if (!sock)
			return Result.err(errors.PROBE_SEND_FAILED, `raw socket: ${socket.error()}`);
		if (!configure(sock, fam, device)) {
			let e = socket.error();
			sock.close();
			return Result.err(errors.PROBE_SEND_FAILED, `raw socket on ${device ?? 'any device'}: ${e}`);
		}
		sockets[key] = { sock: sock, handle: uloop.handle(sock, () => receive(fam, sock), uloop.ULOOP_READ) };
		return Result.ok(sock);
	};

	let transmit = function(host, fam, probe) {
		let opened = open(fam, probe.device);
		if (!opened.ok)
			return opened;
		seq = (seq + 1) & 0xffff;
		let packet = icmp.echo_request(fam, id, seq, icmp.payload(probe.size));
		let addr = { family: (fam == 6) ? socket.AF_INET6 : socket.AF_INET, address: host, port: 0 };
		if (opened.data.send(packet, 0, addr) == null)
			return Result.err(errors.PROBE_SEND_FAILED, `${host}: ${socket.error()}`);
		return Result.ok(`${host} ${seq}`);
	};

	return {
		send: function(probes, timeout, cb) {
			let keys = [];
			for (let probe in probes) {
				let host = canonical_ip(probe.host);
				let fam = icmp.family(host);
				let sent = (fam != null)
					? transmit(host, fam, probe)
					: Result.err(errors.PROBE_SEND_FAILED, `${probe.host}: not an IP address`);
				if (!sent.ok) {
					cb(probe, sent);
					continue;
				}
				pending[sent.data] = { probe: probe, size: probe.size, cb: cb };
				push(keys, sent.data);
			}
			if (length(keys) == 0)
				return;
			uloop.timer(int(timeout * 1000), () => {
				for (let key in keys) {
					let p = pending[key];
					if (p == null)
						continue;
					delete pending[key];
					p.cb(p.probe, Result.ok(false));
				}
			});
		},
	};
};
