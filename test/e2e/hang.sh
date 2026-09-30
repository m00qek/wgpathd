# The daemon hangs without dying: it stops pinging the procd watchdog, procd
# restarts it, and it earns DIRECT again.

baseline
pid=$(daemon_pid spoke-b)
mark_logs
ping_start
started=$(now)
x spoke-b "kill -STOP $pid"

require "procd's watchdog replaces the hung daemon" wait_for 60 pid_changed spoke-b "$pid"
timing watchdog_restart "$(since "$started")"
check "the hung process is gone" x spoke-b "[ ! -d /proc/$pid ]"
check "it starts over in RELAY" wait_for 5 is_state spoke-b RELAY
require "spoke-b DIRECT again" wait_for 60 converged
timing reconverge "$(since "$started")"

ping_stop
check "background ping lost at most 5 s" awk "BEGIN { exit !($PING_GAP <= 5) }"
timing hang_ping_lost "$PING_LOST/$PING_SENT"
