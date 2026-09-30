# The direct path dies while ICMPv6 still answers, only spoke-a is reachable
# (so only spoke-b trials), and spoke-a keeps sending through the relay. Each of
# its packets roams spoke-b's kernel endpoint back onto the relay, so spoke-b's
# trial probe can leave and be answered over the relay. Only an answer that came
# back direct counts: spoke-b is never committed, its trials time
# out and its backoff grows. The traffic itself keeps crossing the relay, apart
# from what each failed trial blackholes. spoke-b does not give the address up
# here: after three failed trials it would stop trialing (direct-filtered shows
# that), and the traffic at 1000 packets/s would meet no trial to race.

uci_set spoke-b give_up_after 100
baseline
unreachable spoke-b
kill_direct
require "both spokes RELAY" wait_for 30 both RELAY
mark_logs
pid_a=$(daemon_pid spoke-a)
pid_b=$(daemon_pid spoke-b)
relayed_before=$(peer spoke-b relayed_answers)

held_on_relay() { daemon_up spoke-a && daemon_up spoke-b && neither DIRECT; }

for rate in 100 1000; do
	traffic_start spoke-a "$(awk -v r="$rate" 'BEGIN { print 1 / r }')"
	check "never DIRECT, both daemons up, under $rate packets/s through the relay" holds 30 held_on_relay
	traffic_stop spoke-a
	check "$rate packets/s crossed the relay" traffic_crossed 50
	timing "relay_${rate}pps_lost" "${TRAFFIC_LOSS}%"
done

check "spoke-a's daemon never restarted" [ "$(daemon_pid spoke-a)" = "$pid_a" ]
check "spoke-b's daemon never restarted" [ "$(daemon_pid spoke-b)" = "$pid_b" ]
relayed=$(($(peer spoke-b relayed_answers) - relayed_before))
timing relayed_answers "$relayed"
check "spoke-b's probes were answered over the relay, and refused" [ "$relayed" -gt 0 ]
check "spoke-b's trials time out" logged spoke-b "reason=trial_timeout"
check "spoke-b's backoff grows to backoff_max" logged spoke-b "reason=trial_timeout backoff=16s"
for n in spoke-a spoke-b; do
	check "$n: no trial_ok" never_logged "$n" "reason=trial_ok"
done
