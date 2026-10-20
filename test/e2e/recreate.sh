# netifd creates wg_mesh again (ifup, a network reload), and the interface starts
# on the endpoints of its configuration. Here spoke-b's configuration names a stale
# address for spoke-a, as a spoke's did after the other's address had changed.
# spoke-b must not take it for a roam: it asserts the direct endpoint again and
# stays DIRECT. The new interface has no WireGuard session until it handshakes
# again, so spoke-a's probes may miss for a moment and demote it; it must come
# straight back.

STALE6=$TRANSIT6::77

ifindex_changed() { n=$(x spoke-b 'cat /sys/class/net/wg_mesh/ifindex 2>/dev/null'); [ -n "$n" ] && [ "$n" != "$1" ]; }

baseline
switches=$(peer spoke-b switches)
ifindex=$(x spoke-b 'cat /sys/class/net/wg_mesh/ifindex')
mark_logs
ping_start
started=$(now)
x spoke-b "uci set network.spoke_a.endpoint_host='$STALE6' && uci set network.spoke_a.endpoint_port='$MESH_PORT' &&
	uci commit network && ifup wg_mesh"

require "netifd created wg_mesh again" wait_for 20 ifindex_changed "$ifindex"
check "spoke-b noticed it" wait_for 15 logged spoke-b "wg_mesh .*created again"
check "spoke-b's kernel is back on spoke-a's direct endpoint" wait_for 15 kernel_on_direct spoke-b
timing reasserted "$(since "$started")"
check "spoke-b never took the configured endpoint for a roam" never_logged spoke-b "roamed endpoint=\[$STALE6\]"
check "spoke-b stayed DIRECT (no RELAY dip)" [ "$(peer spoke-b switches)" = "$switches" ]
check "both back on the direct path" wait_for 30 direct_path
ping_stop
timing recreate_ping_lost "$PING_LOST/$PING_SENT"
check "background ping lost at most 5 s" awk "BEGIN { exit !($PING_GAP <= 5) }"
