# The direct path stops carrying WireGuard while ICMPv6 still answers, as behind a
# firewall that filters UDP: every trial times out. After give_up_after (3)
# timeouts on the same address each spoke gives it up, and the echo alone starts
# no more trials, so cross-site traffic crosses the relay without the gap each
# trial costs. Lifting the filter changes nothing by itself. A new address from
# the hub resumes spoke-a's trials, and spoke-a's direct packets resume spoke-b's
# (a roam); the second time, the end of a short pause does.

followed() { follows "$1" && converged; }
resumed_after_pause() {
	logged spoke-a "trials resumed reason=pause_over" || logged spoke-b "trials resumed reason=pause_over"
}

uci_set spoke-a give_up_pause 600
uci_set spoke-b give_up_pause 600
baseline
mark_logs
kill_direct
require "both spokes RELAY" wait_for 30 both RELAY
require "both give the direct address up" wait_for 120 both_given_up

for n in spoke-a spoke-b; do
	peer_addr="\[$(transit6 "$(other_spoke "$n")")\]:$MESH_PORT"
	check "$n: three trials timed out first" [ "$(logs_since_mark "$n" | grep -c 'reason=trial_timeout')" = 3 ]
	check "$n: the give-up logged" logged "$n" "direct address given up endpoint=$peer_addr failed_trials=3 pause=600s"
	check "$n: status counts the failed trials" [ "$(peer "$n" failed_trials)" = 3 ]
done

mark_logs
ping_start
check "no trial while the address is given up" holds 45 both RELAY
ping_stop
for n in spoke-a spoke-b; do
	check "$n: no trial started" never_logged "$n" "reason=trial_start"
done
check "cross-site traffic crossed the relay without a trial's gap" awk "BEGIN { exit !($PING_GAP <= 1) }"
timing given_up_ping_lost "$PING_LOST/$PING_SENT"

mark_logs
clear_faults
check "lifting the filter alone changes nothing" holds 15 both RELAY
started=$(now)
roam_to "$ROAMED6" "$(transit6 spoke-b)"
require "both DIRECT on spoke-b's new address" wait_for 90 followed "$ROAMED6"
timing resume_on_new_address "$(since "$started")"
check "spoke-a resumed on the new address from the hub" \
	logged spoke-a "direct address trials resumed reason=new_candidate endpoint=\[$(transit6 spoke-b)\]:$MESH_PORT"
check "spoke-b resumed on spoke-a's direct packets" \
	logged spoke-b "direct address trials resumed reason=roam endpoint=\[$(transit6 spoke-a)\]:$MESH_PORT"
roam_to "$(transit6 spoke-b)" "$ROAMED6"
require "back on the original address" wait_for 60 followed "$(transit6 spoke-b)"

uci_set spoke-a give_up_pause 60
uci_set spoke-b give_up_pause 60
mark_logs
kill_direct
require "both give the direct address up again" wait_for 180 both_given_up
clear_faults
started=$(now)
require "both DIRECT once a pause is over" wait_for 120 converged
timing resume_after_pause "$(since "$started")"
check "a spoke resumed when its pause was over" resumed_after_pause
