# Both spokes reachable: both earn DIRECT and site traffic crosses directly.

# The check finds each rule the node's role needs in /etc/config/firewall.
firewall_confirmed() { # node
	out=$(x "$1" 'service wgpathd check')
	echo "$out" | grep -q '^ok    firewall: ' && ! echo "$out" | grep -q '^warn  firewall: '
}

# The rules node.sh adds, named as docs/how-to/open-firewall.md has them.
wgpathd_rules() { # node
	x "$1" "nft list chain inet fw4 input_vpn | grep -c 'comment \"!fw4: Allow-wgpathd-'"
}

baseline
require "cross-site ping" cross_site_ping 5

for n in spoke-a spoke-b; do
	check "$n: kernel endpoint is the peer's direct v6" \
		[ "$(kernel_endpoint "$n")" = "[$(transit6 "$(other_spoke "$n")")]:$MESH_PORT" ]
	check "$n: status endpoint matches the kernel" \
		[ "$(peer "$n" endpoint)" = "$(kernel_endpoint "$n")" ]
	check "$n: hub peer listed as unmanaged, for its fixed endpoint" \
		[ "$(status "$n" '@.unmanaged[*].reason')" = "fixed endpoint" ]
	check "$n: discovery fresh" [ "$(status "$n" '@.discovery.fresh')" = true ]
	check "$n: service wgpathd check passes" x "$n" 'service wgpathd check >/dev/null'
	check "$n: service wgpathd status shows DIRECT" x "$n" 'service wgpathd status | grep -q DIRECT'
	check "$n: trial_ok logged" x "$n" "logread -e wgpathd | grep -q 'transition TRIALING -> DIRECT reason=trial_ok'"
	check "$n: service wgpathd check confirms the firewall" firewall_confirmed "$n"
	check "$n: fw4 carries the two wgpathd rules of /etc/config/firewall" [ "$(wgpathd_rules "$n")" = 2 ]
	check "$n: no rule from the package" [ "$(x "$n" "nft list ruleset | grep -c 'comment \"wgpathd: '")" = 0 ]
done
check "hub: service wgpathd check confirms the firewall" firewall_confirmed hub
check "hub: fw4 carries the wgpathd rule of /etc/config/firewall" [ "$(wgpathd_rules hub)" = 1 ]

check "hub publishes both spokes' direct v6" \
	[ "$(x hub "ubus call wgpathd status | jsonfilter -e '@.peers[*].direct' | sort | tr '\n' ' '")" = \
		"[$(transit6 spoke-a)]:$MESH_PORT [$(transit6 spoke-b)]:$MESH_PORT " ]
check "spoke fetches discovery over wg_hub" \
	x spoke-a "uclient-fetch -qO- http://$(hub_addr hub):$DISCOVERY_PORT/peers | grep -q '$(transit6 spoke-b)'"
