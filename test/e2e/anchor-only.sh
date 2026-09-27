# Only spoke-a is inbound-reachable (the real estate). spoke-b promotes on its
# underlay echo; spoke-a cannot echo spoke-b and promotes on spoke-b's
# authenticated roams instead (design R2, catalog #17).

baseline
unreachable spoke-b
require "spoke-a's underlay echo to spoke-b is refused" \
	x spoke-a "! ping -6 -c1 -W1 $(transit6 spoke-b) >/dev/null 2>&1"
check "spoke-b's underlay echo to spoke-a answers" \
	x spoke-b "ping -6 -c1 -W1 $(transit6 spoke-a) >/dev/null 2>&1"

mark_logs
started=$(now)
restart_daemon spoke-a
restart_daemon spoke-b
require "both spokes start over in RELAY" wait_for 15 both RELAY
require "both spokes DIRECT" wait_for 60 converged
timing anchor_to_direct "$(since "$started")"

check "spoke-a trial started on a roam target" logged spoke-a "transition RELAY -> TRIALING reason=trial_start endpoint=\[$(transit6 spoke-b)\]"
check "cross-site ping" cross_site_ping 5
check "stays DIRECT" holds 10 converged
