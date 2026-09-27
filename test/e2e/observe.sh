# Observe mode: every managed peer is kept on its relay endpoint, and the
# evidence shows only as `ready`.

ready_relay() {
	for n in spoke-a spoke-b; do
		is_state "$n" RELAY && [ "$(peer "$n" ready)" = true ] || return 1
	done
}

baseline
mark_logs
uci_set spoke-a mode observe
uci_set spoke-b mode observe
require "both RELAY and ready" wait_for 30 ready_relay

for n in spoke-a spoke-b; do
	check "$n: mode observe" [ "$(status "$n" @.mode)" = observe ]
	check "$n: left DIRECT for observe_mode" logged "$n" "transition DIRECT -> RELAY reason=observe_mode"
	check "$n: status endpoint is the relay" [ "$(peer "$n" endpoint)" = "$(relay_of "$n")" ]
	check "$n: kernel endpoint is the relay" wait_for 10 kernel_on_relay "$n"
	check "$n: ready logged" logged "$n" "ready, steer would trial"
done
check "stays on the relay" holds 10 ready_relay
check "cross-site ping through the relay" cross_site_ping 5

uci_set spoke-a mode steer
uci_set spoke-b mode steer
require "back to DIRECT in steer mode" wait_for 60 converged
