# Helpers for the e2e scenarios, sourced on the host by devenv/scripts/e2e.sh.
# Every probe of a node goes through `docker exec`; JSON is read inside the node
# with jsonfilter, so the host needs nothing but docker. E2E_PROJECT names the
# stack: wgpathd-e2e for the suite, wgpathd-lab for the lab.

. devenv/services/e2e/topology.sh

HUB6=$(transit6 hub)

x() { # node command...
	node=$1; shift
	docker exec "$E2E_PROJECT-$node" sh -c "$*"
}

xi() { # node command..., stdin passed through
	node=$1; shift
	docker exec -i "$E2E_PROJECT-$node" sh -c "$*"
}

# --- results -----------------------------------------------------------------

pass() { printf 'ok   %s\n' "$*"; printf '%s\tok\t%s\n' "$SCENARIO" "$*" >>"$E2E_OUT/results.tsv"; }
fail() { printf 'FAIL %s\n' "$*"; printf '%s\tFAIL\t%s\n' "$SCENARIO" "$*" >>"$E2E_OUT/results.tsv"; }
note() { printf '     %s\n' "$*"; }

check() { # description command...
	desc=$1; shift
	if "$@"; then pass "$desc"; else fail "$desc"; return 1; fi
}

# Ends the scenario: what follows depends on it.
require() { check "$@" || exit 1; }

timing() { # name value (seconds, or lost/sent)
	printf '     %s: %s\n' "$1" "$2"
	printf '%s\t%s\t%s\n' "$SCENARIO" "$1" "$2" >>"$E2E_OUT/timings.tsv"
}

# --- time ----------------------------------------------------------------------

now() { date +%s.%N; }
since() { awk -v s="$1" -v e="$(now)" 'BEGIN { printf "%.1f", e - s }'; }

# wait_for SECONDS command...: polls every half second; WAITED holds how long it took.
wait_for() {
	limit=$1; shift
	started=$(now)
	while :; do
		if "$@"; then WAITED=$(since "$started"); return 0; fi
		WAITED=$(since "$started")
		awk -v w="$WAITED" -v l="$limit" 'BEGIN { exit !(w >= l) }' && return 1
		sleep 0.5
	done
}

# holds SECONDS command...: the command stays true, sampled every half second.
holds() {
	limit=$1; shift
	started=$(now)
	while awk -v w="$(since "$started")" -v l="$limit" 'BEGIN { exit !(w < l) }'; do
		"$@" || { note "broke after $(since "$started")s"; return 1; }
		sleep 0.5
	done
}

# --- wgpathd -------------------------------------------------------------------

status() { x "$1" "ubus call wgpathd status 2>/dev/null | jsonfilter -e '$2' 2>/dev/null"; }
# Each spoke manages exactly one peer: the other spoke.
peer() { status "$1" "@.peers[*].$2"; }
state() { peer "$1" state; }

is_state() { [ "$(state "$1")" = "$2" ]; }
both() { is_state spoke-a "$1" && is_state spoke-b "$1"; }
neither() { ! is_state spoke-a "$1" && ! is_state spoke-b "$1"; }

# The spoke has given its peer's direct address up after failed trials.
given_up() { [ -n "$(peer "$1" given_up.since)" ]; }
both_given_up() { given_up spoke-a && given_up spoke-b; }

# The daemon answers status for its peer.
daemon_up() { [ -n "$(state "$1")" ]; }

daemon_pid() {
	x "$1" "ubus call service list '{\"name\":\"wgpathd\"}' | jsonfilter -e '@.wgpathd.instances.wgpathd.pid'"
}
pid_changed() { p=$(daemon_pid "$1"); [ -n "$p" ] && [ "$p" != "$2" ]; }

discovery_fresh() { [ "$(status "$1" @.discovery.fresh)" = true ]; }

relay_of() { echo "$(hub_addr "$(other_spoke "$1")"):$MESH_PORT"; }

# The endpoint the kernel holds for the other spoke, whoever set it.
kernel_endpoint() {
	x "$1" "wg show wg_mesh endpoints | grep \"^\$(cat /keys/$(other_spoke "$1").wg_mesh.pub)\" | cut -f2"
}

kernel_on_relay() { [ "$(kernel_endpoint "$1")" = "$(relay_of "$1")" ]; }
kernel_on_direct() { [ "$(kernel_endpoint "$1")" = "[$(transit6 "$(other_spoke "$1")")]:$MESH_PORT" ]; }

# spoke-a holds spoke-b's direct endpoint at this address.
follows() { [ "$(kernel_endpoint spoke-a)" = "[$1]:$MESH_PORT" ]; }

# Log lines since mark_logs, so a scenario sees only its own.
mark_logs() {
	for n in spoke-a spoke-b; do
		eval "LOGMARK_${n#spoke-}=$(x "$n" 'logread -e wgpathd | wc -l')"
	done
}
logs_since_mark() {
	eval "m=\$LOGMARK_${1#spoke-}"
	x "$1" "logread -e wgpathd | tail -n +$((m + 1))"
}
logged() { logs_since_mark "$1" | grep -q -- "$2"; }
never_logged() { ! logged "$@"; }

restart_daemon() { x "$1" 'service wgpathd restart'; }

# uci_set node option value...: changes /etc/config/wgpathd and reloads.
uci_set() {
	node=$1; shift
	while [ $# -ge 2 ]; do
		x "$node" "uci set wgpathd.main.$1='$2'"
		shift 2
	done
	x "$node" 'uci commit wgpathd && service wgpathd reload'
}

# --- traffic -------------------------------------------------------------------

PING=/usr/libexec/iputils-ping
SITE_ROUTE="-I $(site_addr spoke-a) $(site_addr spoke-b)"

cross_site_ping() { x spoke-a "$PING -q -c${1:-3} -i0.2 -W1 $SITE_ROUTE" >/dev/null; }
# Packets that fill the wg_mesh MTU, which nothing on the way may fragment.
full_size_ping() { x spoke-a "$PING -q -c${1:-3} -i0.2 -W1 -M do -s $((MESH_MTU - 28)) $SITE_ROUTE" >/dev/null; }

# A 5 Hz ping from site a to site b in the background, measured by ping_stop.
ping_start() {
	x spoke-a 'killall -q iputils-ping; rm -f /tmp/bgping.log'
	docker exec -d "$E2E_PROJECT-spoke-a" sh -c "exec $PING -i0.2 -W1 $SITE_ROUTE >/tmp/bgping.log 2>&1"
}

# Sets PING_SENT, PING_LOST and PING_GAP (longest run of lost replies, in seconds).
ping_stop() {
	x spoke-a 'killall -INT iputils-ping; sleep 1'
	set -- $(x spoke-a "awk '
		/bytes from.*icmp_seq=/ { sub(/.*icmp_seq=/, \"\"); seq = \$1 + 0
		              if (seq - last - 1 > gap) gap = seq - last - 1; last = seq }
		/packets transmitted/ { sent = \$1; got = \$4 }
		END { if (sent - last > gap) gap = sent - last; print sent + 0, sent - got, gap * 0.2 }
	' /tmp/bgping.log")
	PING_SENT=$1 PING_LOST=$2 PING_GAP=$3
	note "background ping: $PING_SENT sent, $PING_LOST lost, longest gap ${PING_GAP}s"
}

# Steady traffic from one site to the other: a ping every INTERVAL seconds
# (0.001 is 1000 packets/s), measured by traffic_stop.
traffic_start() { # from interval
	x "$1" 'killall -q iputils-ping; rm -f /tmp/traffic.log'
	docker exec -d "$E2E_PROJECT-$1" sh -c \
		"exec $PING -q -i$2 -W1 -I $(site_addr "$1") $(site_addr "$(other_spoke "$1")") >/tmp/traffic.log 2>&1"
}

# Sets TRAFFIC_LOSS, the percentage of the traffic lost; empty if the ping never ran.
traffic_stop() { # from
	x "$1" 'killall -INT iputils-ping; sleep 1'
	TRAFFIC_LOSS=$(x "$1" "grep -o '[0-9.]*% packet loss' /tmp/traffic.log | cut -d% -f1")
	note "traffic from $1: ${TRAFFIC_LOSS:-no}% lost"
}

# The traffic ran and lost less than PERCENT of its packets.
traffic_crossed() { # percent
	[ -n "$TRAFFIC_LOSS" ] && awk -v l="$TRAFFIC_LOSS" -v m="$1" 'BEGIN { exit !(l < m) }'
}

# --- faults: an nftables table of the harness's own, beside fw4's --------------

fault() { # node chain rule...
	node=$1 chain=$2; shift 2
	xi "$node" 'nft -f -' <<-EOF
		table inet e2e {
			chain input { type filter hook input priority -10; policy accept; }
			chain output { type filter hook output priority -10; policy accept; }
		}
		add rule inet e2e $chain $*
	EOF
}

clear_faults() {
	for n in hub spoke-a spoke-b; do x "$n" 'nft delete table inet e2e 2>/dev/null; true'; done
	x hub 'tc qdisc del dev eth0 root 2>/dev/null; true'
}

# Only the v6 wg_mesh datagrams between the spokes; the hub leg, the relay (v4
# over wg_hub) and ICMPv6 stay up, so the underlay echo still says "reachable".
kill_direct() {
	for n in spoke-a spoke-b; do
		fault "$n" output "ip6 daddr != $HUB6 udp dport $MESH_PORT drop"
		fault "$n" input "ip6 saddr != $HUB6 udp sport $MESH_PORT drop"
	done
}

# Direct-path wg_mesh datagrams longer than SIZE bytes are dropped both ways, like
# a link with a smaller MTU that drops what does not fit instead of reporting it.
# Small datagrams, the hub leg, the relay and ICMPv6 all pass.
mtu_blackhole() { # size
	for n in spoke-a spoke-b; do
		fault "$n" output "ip6 daddr != $HUB6 udp dport $MESH_PORT meta length > $1 drop"
		fault "$n" input "ip6 saddr != $HUB6 udp sport $MESH_PORT meta length > $1 drop"
	done
}

# Everything the hub sends waits MS milliseconds. The hub carries the relay,
# discovery and the wg_hub leg, never the direct path between the spokes, so
# only relayed traffic slows down: by MS each way, 2 * MS on a round trip.
relay_delay() { # ms
	x hub "tc qdisc replace dev eth0 root netem delay ${1}ms"
}

# A site behind a stateful firewall without NAT: nothing unsolicited gets in
# over IPv6 except from the hub, whose leg the spoke keeps open anyway.
unreachable() {
	fault "$1" input "icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept"
	fault "$1" input "ip6 saddr != $HUB6 ct state new drop"
	x "$1" 'conntrack -F 2>/dev/null; true'
}

# --- topology ------------------------------------------------------------------

roam_to() { # new-address old-address
	x spoke-b "ip -6 addr add $1/64 dev eth0 nodad && ip -6 addr del $2/64 dev eth0"
}

# Undoes whatever a scenario left behind, finished or not: faults, a stopped
# daemon, a changed role file, a roamed address, a configured mesh endpoint, and a given-up direct address,
# which would keep the next scenario off the direct path for give_up_pause.
restore_all() {
	clear_faults
	for n in spoke-a spoke-b; do
		x "$n" 'killall -q iputils-ping
			killall -CONT ucode 2>/dev/null
			cmp -s /etc/config/wgpathd /etc/config/wgpathd.e2e && exit
			cp /etc/config/wgpathd.e2e /etc/config/wgpathd && service wgpathd restart'
		! given_up "$n" || restart_daemon "$n"
	done
	x spoke-b "ip -6 addr add $(transit6 spoke-b)/64 dev eth0 nodad 2>/dev/null
		ip -6 addr del $ROAMED6/64 dev eth0 2>/dev/null; true"
	x spoke-b 'uci -q get network.spoke_a.endpoint_host >/dev/null || exit 0
		uci delete network.spoke_a.endpoint_host; uci -q delete network.spoke_a.endpoint_port
		uci commit network && ifup wg_mesh'
}

converged() { both DIRECT; }
# Both DIRECT, and each kernel really holds the other's direct endpoint.
direct_path() { converged && kernel_on_direct spoke-a && kernel_on_direct spoke-b; }

baseline() { require "both spokes DIRECT" wait_for 90 converged; }
