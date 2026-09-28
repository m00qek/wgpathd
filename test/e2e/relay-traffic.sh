# The direct path dies while ICMPv6 still answers, only spoke-a is reachable
# (so only spoke-b trials), and spoke-a keeps sending through the relay. Each of
# its packets roams spoke-b's kernel endpoint back onto the relay, so spoke-b's
# trial probe can leave and be answered over the relay. Only an answer that came
# back direct counts (design R4): spoke-b is never committed, its trials time
# out and its backoff grows.

never_logged() { ! logged "$@"; }

baseline
unreachable spoke-b
kill_direct
require "both spokes RELAY" wait_for 30 both RELAY
mark_logs

for rate in 100 1000; do
	traffic_start spoke-a "$(awk -v r="$rate" 'BEGIN { print 1 / r }')"
	check "never DIRECT under $rate packets/s through the relay" holds 30 neither DIRECT
	traffic_stop spoke-a
	timing "relay_${rate}pps_lost" "${TRAFFIC_LOSS}%"
done

check "spoke-b's trials time out" logged spoke-b "reason=trial_timeout"
check "spoke-b's backoff grows to backoff_max" logged spoke-b "reason=trial_timeout backoff=16s"
for n in spoke-a spoke-b; do
	check "$n: no trial_ok" never_logged "$n" "reason=trial_ok"
done
