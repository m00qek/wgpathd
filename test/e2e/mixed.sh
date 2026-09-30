# One side DIRECT, the other held in RELAY by a long backoff: the RELAY side's
# re-assert and the DIRECT side's packets move its endpoint back and forth each
# cycle, and site traffic loses nothing: each side decides only where it sends.

uci_set spoke-b backoff_min 300 backoff_max 300
# A fresh daemon has no backoff yet, so its demotion sets backoff_min exactly.
restart_daemon spoke-b
baseline
kill_direct
require "both spokes RELAY" wait_for 30 both RELAY
clear_faults

require "spoke-a DIRECT again" wait_for 60 is_state spoke-a DIRECT
require "spoke-b held in RELAY by its backoff" is_state spoke-b RELAY
mixed() { is_state spoke-a DIRECT && is_state spoke-b RELAY; }
ping_start
check "the mixed state holds" holds 20 mixed
ping_stop
check "background ping lost nothing" [ "$PING_LOST" = 0 ]
timing mixed_ping_lost "$PING_LOST/$PING_SENT"
