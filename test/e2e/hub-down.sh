# The whole hub goes dark: established direct sessions are peer to peer and
# survive (catalog #2), and a roamer is still followed without it (#3).
# The hub is cut off inside its own namespace, not stopped, to spare docker
# network churn on the host.

baseline
mark_logs
ping_start
fault hub input 'iifname "eth0" drop'
fault hub output 'oifname "eth0" drop'

check "both stay DIRECT without the hub" holds 20 converged
check "discovery failure logged" logged spoke-a "discovery failed"

roam_to "$ROAMED6" "$(transit6 spoke-b)"
check "spoke-a follows the roamer without the hub" wait_for 30 follows "$ROAMED6"
check "both still DIRECT after the roam" holds 5 converged
roam_to "$(transit6 spoke-b)" "$ROAMED6"
check "and back" wait_for 30 follows "$(transit6 spoke-b)"

ping_stop
check "background ping lost at most 2 s" awk "BEGIN { exit !($PING_GAP <= 2) }"
timing hub_down_ping_lost "$PING_LOST/$PING_SENT"

clear_faults
check "discovery recovers" wait_for 30 discovery_fresh spoke-a
