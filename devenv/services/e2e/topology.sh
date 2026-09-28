# Addressing plan of the e2e topology, sourced by the node entrypoint and the
# scenarios. The docker addresses are repeated in devenv/e2e.compose.yaml.

TRANSIT4=172.31.250
TRANSIT6=fd77:e2e0:0:1
MESH_PORT=51820
# The wg_mesh MTU of every node; full-size probes and pings fill it.
MESH_MTU=1360
HUB_WG_PORT=51830
DISCOVERY_PORT=7780

host_id() {
	case $1 in
	hub) echo 10 ;;
	spoke-a) echo 11 ;;
	spoke-b) echo 12 ;;
	esac
}

transit4() { echo "$TRANSIT4.$(host_id "$1")"; }
transit6() { echo "$TRANSIT6::$(host_id "$1")"; }
# Where spoke-b moves in the roam scenario.
ROAMED6=$TRANSIT6::22

# The hub is .1 in both tunnel ranges; a spoke keeps its transit host id.
tunnel_id() { if [ "$1" = hub ]; then echo 1; else host_id "$1"; fi; }
hub_addr() { echo "10.10.0.$(tunnel_id "$1")"; }
mesh_addr() { echo "10.20.0.$(tunnel_id "$1")"; }

# Each spoke holds one address of its own site network, so cross-site traffic
# needs no client containers.
site_net() {
	case $1 in
	spoke-a) echo 10.11 ;;
	spoke-b) echo 10.12 ;;
	esac
}
site_addr() { echo "$(site_net "$1").0.1"; }

other_spoke() { if [ "$1" = spoke-a ]; then echo spoke-b; else echo spoke-a; fi; }
