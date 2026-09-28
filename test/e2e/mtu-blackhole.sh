# The direct path keeps carrying small packets but drops large ones, while
# ICMPv6 still answers. A small tunnel probe would keep both spokes DIRECT while
# full-size site traffic dies; the tunnel probe fills the wg_mesh MTU, so both
# fall back to the relay, where full-size packets fit, and no trial commits.
# The drop threshold passes every packet a small probe needs but not one of
# MESH_MTU bytes, which is 80 bytes more on the underlay.

baseline
mark_logs
started=$(now)
mtu_blackhole 1200

require "both spokes RELAY" wait_for 30 both RELAY
timing failover "$(since "$started")"

for n in spoke-a spoke-b; do
	check "$n: demotion logged" logged "$n" "transition DIRECT -> RELAY reason=demoted"
done
check "small cross-site ping" cross_site_ping 5
check "full-size cross-site ping through the relay" full_size_ping 5
check "direct stays refused while small packets cross it" holds 20 neither DIRECT
for n in spoke-a spoke-b; do
	check "$n: no trial_ok" never_logged "$n" "reason=trial_ok"
done

started=$(now)
clear_faults
require "both spokes DIRECT again" wait_for 60 direct_path
timing restore "$(since "$started")"
check "full-size cross-site ping over the direct path" full_size_ping 5
