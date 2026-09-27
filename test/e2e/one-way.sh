# Direct datagrams get from spoke-b to spoke-a but never back, while ICMPv6 answers
# both ways: the in-tunnel round trip fails every trial, so neither is promoted
# (catalog #10).

baseline
fault spoke-a output "ip6 daddr != $HUB6 udp dport $MESH_PORT drop"
restart_daemon spoke-a
restart_daemon spoke-b
require "both spokes RELAY" wait_for 15 both RELAY
mark_logs

check "never promoted" holds 30 neither DIRECT
for n in spoke-a spoke-b; do
	if logged "$n" "reason=trial_timeout"; then note "$n: trials attempted and timed out"; fi
done
check "cross-site ping through the relay" cross_site_ping 10
