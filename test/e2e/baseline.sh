# Both spokes reachable: both earn DIRECT and site traffic crosses directly.

baseline
require "cross-site ping" cross_site_ping 5

for n in spoke-a spoke-b; do
	check "$n: kernel endpoint is the peer's direct v6" \
		[ "$(kernel_endpoint "$n")" = "[$(transit6 "$(other_spoke "$n")")]:$MESH_PORT" ]
	check "$n: status endpoint matches the kernel" \
		[ "$(peer "$n" endpoint)" = "$(kernel_endpoint "$n")" ]
	check "$n: hub peer listed as unmanaged" \
		[ "$(status "$n" '@.unmanaged[*].reason')" = "missing wgpathd_relay" ]
	check "$n: discovery fresh" [ "$(status "$n" '@.discovery.fresh')" = true ]
	check "$n: service wgpathd check passes" x "$n" 'service wgpathd check >/dev/null'
	check "$n: service wgpathd status shows DIRECT" x "$n" 'service wgpathd status | grep -q DIRECT'
	check "$n: trial_ok logged" x "$n" "logread -e wgpathd | grep -q 'transition TRIALING -> DIRECT reason=trial_ok'"
	check "$n: fw4 carries the four wgpathd rules" \
		[ "$(x "$n" "nft list chain inet fw4 input | grep -c 'comment \"wgpathd: '")" = 4 ]
done

check "hub publishes both spokes' direct v6" \
	[ "$(x hub "ubus call wgpathd status | jsonfilter -e '@.peers[*].direct' | sort | tr '\n' ' '")" = \
		"[$(transit6 spoke-a)]:$MESH_PORT [$(transit6 spoke-b)]:$MESH_PORT " ]
check "spoke fetches discovery over wg_hub" \
	x spoke-a "uclient-fetch -qO- http://$(hub_addr hub):$DISCOVERY_PORT/peers | grep -q '$(transit6 spoke-b)'"
