#!/bin/sh
# Entrypoint of hub, spoke-a and spoke-b: install the built package, render the
# node's UCI config (the substrate the design's render layer owns, plus
# /etc/config/wgpathd outside the lab), then hand over to procd so netifd, fw4,
# rpcd and the wgpathd service boot for real.
set -e
. /e2e/topology.sh

node=$E2E_NODE
role=${node%%-*}

install_package() {
	apk=$(ls -t /artifacts/wgpathd-*.apk | head -n1)
	mkdir -p /var/lock /var/run
	# The postinst's firewall reload has no procd yet and fails; fw4 loads at boot.
	apk add --allow-untrusted --no-network "$apk" >/tmp/wgpathd-install.log 2>&1
}

key() { cat "/keys/$1.$2.key"; }
pub() { cat "/keys/$1.$2.pub"; }

# netifd owns eth0 with the addresses docker assigned: preinit flushes and
# downs the board's first interface before procd starts the network.
common_network() {
	cat <<-EOF
		config interface 'loopback'
		option device 'lo'
		option proto 'static'
		option ipaddr '127.0.0.1/8'

		config interface 'wan'
		option device 'eth0'
		option proto 'static'
		option ipaddr '$(transit4 "$node")/24'
		option ip6addr '$(transit6 "$node")/64'

	EOF
}

wg_interface() { # name address [port] [mtu]
	cat <<-EOF
		config interface '$1'
		option proto 'wireguard'
		option private_key '$(key "$node" "$1")'
		list addresses '$2'
	EOF
	[ -z "$3" ] || printf "\toption listen_port '%s'\n" "$3"
	[ -z "$4" ] || printf "\toption mtu '%s'\n" "$4"
	echo
}

hub_network() {
	common_network
	wg_interface wg_hub "$(hub_addr hub)/24" "$HUB_WG_PORT"
	wg_interface wg_mesh "$(mesh_addr hub)/32" "$MESH_PORT" "$MESH_MTU"
	for spoke in spoke-a spoke-b; do
		cat <<-EOF
			config wireguard_wg_hub 'hub_${spoke#spoke-}'
			option public_key '$(pub "$spoke" wg_hub)'
			list allowed_ips '$(hub_addr "$spoke")/32'
			option route_allowed_ips '1'

			config wireguard_wg_mesh 'mesh_${spoke#spoke-}'
			option public_key '$(pub "$spoke" wg_mesh)'
			list allowed_ips '$(mesh_addr "$spoke")/32'
			option route_allowed_ips '1'

		EOF
	done
}

# The steered peer carries no endpoint: wgpathd owns it at runtime.
spoke_network() {
	peer=$(other_spoke "$node")
	common_network
	cat <<-EOF
		config device
		option name 'br-lan'
		option type 'bridge'
		option bridge_empty '1'

		config interface 'lan'
		option device 'br-lan'
		option proto 'static'
		option ipaddr '$(site_addr "$node")/16'

	EOF
	wg_interface wg_hub "$(hub_addr "$node")/32"
	wg_interface wg_mesh "$(mesh_addr "$node")/32" "$MESH_PORT" "$MESH_MTU"
	cat <<-EOF
		config wireguard_wg_hub 'hub_transit'
		option public_key '$(pub hub wg_hub)'
		option endpoint_host '$(transit4 hub)'
		option endpoint_port '$HUB_WG_PORT'
		list allowed_ips '10.10.0.0/24'
		option route_allowed_ips '1'
		option persistent_keepalive '25'

		config wireguard_wg_mesh 'hub'
		option public_key '$(pub hub wg_mesh)'
		option endpoint_host '$(transit6 hub)'
		option endpoint_port '$MESH_PORT'
		list allowed_ips '$(mesh_addr hub)/32'
		option route_allowed_ips '1'
		option persistent_keepalive '25'

		config wireguard_wg_mesh 'spoke_${peer#spoke-}'
		option public_key '$(pub "$peer" wg_mesh)'
		list allowed_ips '$(site_net "$peer").0.0/16'
		list allowed_ips '$(mesh_addr "$peer")/32'
		option route_allowed_ips '1'
		option wgpathd_relay '$(hub_addr "$peer"):$MESH_PORT'
		option wgpathd_tunnel '$(mesh_addr "$peer")'
	EOF
}

wan_rule() { # name proto port [family]
	cat <<-EOF
		config rule
		option name '$1'
		option src 'wan'
		option proto '$2'
		option dest_port '$3'
		option target 'ACCEPT'
	EOF
	[ -z "$4" ] || printf "\toption family '%s'\n" "$4"
	echo
}

# The vpn zone rejects input, so the probe, discovery and relay-ingress accepts
# come only from the package's fw4 include. ICMPv6 echo is left out of the WAN
# rule for the same reason.
common_firewall() {
	cat <<-EOF
		config defaults
		option input 'REJECT'
		option output 'ACCEPT'
		option forward 'REJECT'

		config zone
		option name 'wan'
		list network 'wan'
		option input 'REJECT'
		option output 'ACCEPT'
		option forward 'REJECT'

		config zone
		option name 'vpn'
		list network 'wg_hub'
		list network 'wg_mesh'
		option input 'REJECT'
		option output 'ACCEPT'
		option forward 'REJECT'

		config rule
		option name 'Allow-ICMPv6-Input'
		option src 'wan'
		option proto 'icmp'
		option family 'ipv6'
		list icmp_type 'destination-unreachable'
		list icmp_type 'packet-too-big'
		list icmp_type 'time-exceeded'
		list icmp_type 'neighbour-solicitation'
		list icmp_type 'neighbour-advertisement'
		option target 'ACCEPT'

	EOF
}

hub_firewall() {
	common_firewall
	wan_rule Allow-wg_hub udp "$HUB_WG_PORT"
	wan_rule Allow-wg_mesh udp "$MESH_PORT" ipv6
	cat <<-EOF
		config rule
		option name 'wg_hub-transit'
		option src 'vpn'
		option dest 'vpn'
		option dest_ip '10.10.0.0/24'
		option target 'ACCEPT'
	EOF
}

# Both spokes open wg_mesh on WAN; the scenarios take reachability away with
# their own nftables table.
spoke_firewall() {
	common_firewall
	wan_rule Allow-wg_mesh udp "$MESH_PORT" ipv6
	cat <<-EOF
		config zone
		option name 'lan'
		list network 'lan'
		option input 'ACCEPT'
		option output 'ACCEPT'
		option forward 'ACCEPT'

		config forwarding
		option src 'lan'
		option dest 'vpn'

		config forwarding
		option src 'vpn'
		option dest 'lan'
	EOF
}

hub_wgpathd() {
	cat <<-EOF
		config wgpathd 'main'
		option enabled '1'
		option role 'hub'
		option read_iface 'wg_mesh'
		option serve_addr '$(hub_addr hub)'
		option serve_port '$DISCOVERY_PORT'
		option cycle '1'
	EOF
}

# Fast parameters, so a failover completes in seconds (design "Running it").
spoke_wgpathd() {
	cat <<-EOF
		config wgpathd 'main'
		option enabled '1'
		option role 'spoke'
		option mesh_iface 'wg_mesh'
		option hub_iface 'wg_hub'
		option discovery 'http://$(hub_addr hub):$DISCOVERY_PORT/peers'
		option mode 'steer'
		option cycle '1'
		option n_up '3'
		option m_down '2'
		option tunnel_timeout '1'
		option trial_window '4'
		option backoff_min '4'
		option backoff_max '16'
		option backoff_reset '30'
		option discovery_interval '5'
	EOF
}

install_package
"${role}_network" >/etc/config/network
"${role}_firewall" >/etc/config/firewall
# The lab keeps the shipped, disabled config: configuring it is the lesson.
if [ -z "${E2E_LAB:-}" ]; then
	"${role}_wgpathd" >/etc/config/wgpathd
	# The scenarios restore this after changing the role file.
	cp /etc/config/wgpathd /etc/config/wgpathd.e2e
fi
/etc/init.d/wgpathd enable

exec /sbin/init
