# Only spoke-a is reachable, and steady traffic crosses between the sites while
# both spokes start over in RELAY. Traffic sent through the relay keeps roaming
# the other side's kernel back onto it, yet the answer to spoke-b's trial must
# come back direct (design R4). spoke-a trials on the first authenticated roam
# (R2), so both still reach DIRECT, with each kernel really on the direct path.

restarted() { pid_changed spoke-a "$pid_a" && pid_changed spoke-b "$pid_b"; }

reconverge_under() { # from packets/s
	traffic_start "$1" "$(awk -v r="$2" 'BEGIN { print 1 / r }')"
	pid_a=$(daemon_pid spoke-a)
	pid_b=$(daemon_pid spoke-b)
	started=$(now)
	restart_daemon spoke-a
	restart_daemon spoke-b
	require "both daemons restarted, so both start over in RELAY" wait_for 10 restarted
	require "both DIRECT under $2 packets/s from $1" wait_for 60 direct_path
	timing "direct_under_${2}pps_from_${1#spoke-}" "$(since "$started")"
	check "stays DIRECT" holds 10 direct_path
	traffic_stop "$1"
	timing "lost_${2}pps_from_${1#spoke-}" "${TRAFFIC_LOSS}%"
}

baseline
unreachable spoke-b
mark_logs
reconverge_under spoke-a 100
reconverge_under spoke-a 1000
reconverge_under spoke-b 1000
check "spoke-a trialed toward spoke-b's roamed source" \
	logged spoke-a "transition RELAY -> TRIALING reason=trial_start endpoint=\[$(transit6 spoke-b)\]"
