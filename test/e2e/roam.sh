# spoke-b's IPv6 address changes while DIRECT: its next packets reach spoke-a from
# the new source, spoke-a adopts the authenticated roam and both stay or get
# back to DIRECT.

followed() { follows "$1" && converged; }

baseline
switches=$(peer spoke-a switches)
mark_logs
ping_start
started=$(now)
roam_to "$ROAMED6" "$(transit6 spoke-b)"

require "spoke-a follows spoke-b to its new address" wait_for 60 followed "$ROAMED6"
timing reacquire "$(since "$started")"
if logged spoke-a "roamed endpoint=\[$ROAMED6\]"; then
	note "spoke-a adopted the roam in DIRECT"
fi
check "spoke-a stayed DIRECT (no RELAY dip)" [ "$(peer spoke-a switches)" = "$switches" ]
check "hub publishes the new address" wait_for 40 x hub "ubus call wgpathd status | grep -q '$ROAMED6'"
ping_stop
timing roam_ping_lost "$PING_LOST/$PING_SENT"
check "background ping lost at most 5 s" awk "BEGIN { exit !($PING_GAP <= 5) }"

roam_to "$(transit6 spoke-b)" "$ROAMED6"
require "back on the original address" wait_for 60 followed "$(transit6 spoke-b)"
