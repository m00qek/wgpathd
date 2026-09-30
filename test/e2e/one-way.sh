# Direct datagrams get from spoke-b to spoke-a but never back, while ICMPv6 answers
# both ways: the in-tunnel round trip fails every trial, so neither is promoted.
# After give_up_after (3) failed trials on the address each spoke
# gives it up, and once both have, no trial starts again.

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
require "both give the address up" wait_for 60 both_given_up
for n in spoke-a spoke-b; do
	check "$n: the give-up logged" logged "$n" "direct address given up"
done
check "no trial once both have given up" holds 20 neither TRIALING
check "cross-site ping through the relay" cross_site_ping 10
