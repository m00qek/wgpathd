# The daemon dies: procd respawns it, it starts in RELAY and earns DIRECT again.

baseline
pid=$(daemon_pid spoke-a)
mark_logs
ping_start
started=$(now)
x spoke-a "kill -KILL $pid"

require "procd respawns the daemon" wait_for 20 pid_changed spoke-a "$pid"
timing respawn "$(since "$started")"
check "the new daemon logged its start" wait_for 5 logged spoke-a "started role=spoke"
check "it starts over in RELAY" wait_for 5 is_state spoke-a RELAY
require "spoke-a DIRECT again" wait_for 60 converged
timing reconverge "$(since "$started")"

ping_stop
check "background ping lost at most 5 s" awk "BEGIN { exit !($PING_GAP <= 5) }"
timing crash_ping_lost "$PING_LOST/$PING_SENT"
