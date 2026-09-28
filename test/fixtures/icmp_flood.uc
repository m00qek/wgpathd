// Floods the loopback with large ICMP echo requests for a bounded time, for the
// prober's flood test: ucode icmp_flood.uc SECONDS PAYLOAD_SIZE
import * as socket from 'socket';

let seconds = +ARGV[0];
let size = +ARGV[1];

function u16(n) {
	return chr((n >> 8) & 0xff, n & 0xff);
}

let data = '';
while (length(data) < size)
	data += 'flood ';
data = substr(data, 0, size);
let sum = 0x0800 + 0x0f0f + 1;
for (let i = 0; i < size; i += 2)
	sum += (ord(data, i) << 8) | ((i + 1 < size) ? ord(data, i + 1) : 0);
while (sum > 0xffff)
	sum = (sum & 0xffff) + (sum >> 16);
let packet = chr(8, 0) + u16(~sum & 0xffff) + u16(0x0f0f) + u16(1) + data;

let sock = socket.create(socket.AF_INET, socket.SOCK_RAW, 1);
let addr = { family: socket.AF_INET, address: '127.0.0.1', port: 0 };
let now = () => clock(true)[0] + clock(true)[1] / 1e9;
let until = now() + seconds;
while (now() < until)
	for (let i = 0; i < 20; i++)
		sock.send(packet, 0, addr);
