# The direct path dies: both spokes fall back to the relay floor and site traffic
# keeps flowing through the hub (relay endpoint, fw4 relay-ingress rule, hub
# forwarding); once it returns, both earn DIRECT again.

baseline
mark_logs
ping_start
started=$(now)
kill_direct

require "both spokes RELAY" wait_for 30 both RELAY
timing failover "$(since "$started")"

for n in spoke-a spoke-b; do
	check "$n: status endpoint is the relay floor" [ "$(peer "$n" endpoint)" = "$(relay_of "$n")" ]
	check "$n: demotion logged" logged "$n" "transition DIRECT -> RELAY reason=demoted"
done
check "cross-site ping through the relay" cross_site_ping 10
check "direct stays refused while ICMPv6 says reachable" holds 10 neither DIRECT

ping_stop
check "background ping lost at most 15 s" awk "BEGIN { exit !($PING_GAP <= 15) }"
timing failover_ping_gap "$PING_GAP"
timing failover_ping_lost "$PING_LOST/$PING_SENT"

started=$(now)
clear_faults
require "both spokes DIRECT again" wait_for 60 converged
timing restore "$(since "$started")"
check "cross-site ping after restore" cross_site_ping 5
