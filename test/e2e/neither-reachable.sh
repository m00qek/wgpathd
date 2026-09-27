# No anchor: neither spoke accepts unsolicited IPv6, so neither has evidence and
# both stay on the relay for good (catalog #15), with site traffic intact.

baseline
unreachable spoke-a
unreachable spoke-b
restart_daemon spoke-a
restart_daemon spoke-b
require "both spokes RELAY" wait_for 15 both RELAY

check "neither leaves RELAY" holds 20 both RELAY
for n in spoke-a spoke-b; do
	check "$n: no transition at all" [ "$(peer "$n" switches)" = 0 ]
done
check "cross-site ping through the relay" cross_site_ping 10
