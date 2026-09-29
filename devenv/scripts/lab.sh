#!/bin/sh
# The e2e topology left running for a learner (docs/tutorials/first-failover.md):
# the WireGuard substrate and the firewall rules wgpathd needs in place, wgpathd
# installed but disabled on every node.
# usage: lab.sh up | down | shell NODE | fault kill-direct|relay-delay MS|restore
#
# The e2e host guard (host-guard.sh) covers the lab's whole life: `up` leaves
# its watchdog running detached, and only `down` stops it.
set -u
cd "$(dirname "$0")/../.."

PROJECT=wgpathd-lab
OUT=$PWD/bin/lab
SELF=$PWD/devenv/scripts/lab.sh
. devenv/scripts/host-guard.sh
. test/e2e/lib.sh
export E2E_LAB=1

running() { [ -f "$OUT/watchdog.pid" ] && kill -0 "$(cat "$OUT/watchdog.pid")" 2>/dev/null; }

require_up() {
	[ ! -f "$OUT/ABORTED" ] || die "the host guard stopped the lab: $(cat "$OUT/ABORTED")"
	running || die "the lab is not up (make lab-up)"
}

# Also tells the terminal that ran `up`, which may be waiting in a lab shell.
abort() {
	monitors_stop
	term=$(cat "$OUT/tty" 2>/dev/null)
	[ ! -w "$term" ] || cat "$OUT/ABORTED" >"$term"
}

hub_handshakes() { # iface
	x hub "wg show $1 latest-handshakes 2>/dev/null" | awk '$2 > 0' | wc -l
}
substrate_ready() { [ "$(hub_handshakes wg_hub)" = 2 ] && [ "$(hub_handshakes wg_mesh)" = 2 ]; }

fail_up() {
	echo "lab: $*" >&2
	down
	exit 1
}

up() {
	! running || die "the lab is already up (make lab-down first)"
	: "${PKG_DEPENDS:?run through make lab-up}"
	preflight
	monitors_start
	echo up >"$OUT/current"
	tty >"$OUT/tty" 2>/dev/null
	setsid "$SELF" watchdog </dev/null >>"$OUT/watchdog.log" 2>&1 &
	echo $! >"$OUT/watchdog.pid"

	echo "lab: building the package and the image"
	make -s package CI=1 >"$OUT/build.log" 2>&1 || fail_up "make package failed, see $OUT/build.log"
	$COMPOSE build -q >>"$OUT/build.log" 2>&1 || fail_up "image build failed, see $OUT/build.log"
	echo "lab: starting hub, spoke-a and spoke-b"
	$COMPOSE up -d --quiet-pull >"$OUT/up.log" 2>&1 || fail_up "compose up failed, see $OUT/up.log"
	wait_for 90 substrate_ready || fail_up "the WireGuard substrate did not come up"
	echo lab >"$OUT/current"
	echo "lab: up, wgpathd installed and disabled on hub, spoke-a and spoke-b"
	echo "lab: open a node with 'make lab-shell NODE=<node>', stop with 'make lab-down'"
}

down() {
	if running; then kill "$(cat "$OUT/watchdog.pid")"; fi
	rm -f "$OUT/watchdog.pid"
	if [ ! -f "$OUT/sysctl.before" ]; then
		$COMPOSE down -v --remove-orphans >/dev/null 2>&1
		echo "lab: not up"
		return
	fi
	echo "lab: tearing down"
	stack_down
	host_report
}

shell() { # node
	require_up
	case ${1:-} in
	hub | spoke-a | spoke-b) exec docker exec -it "$PROJECT-$1" sh -l ;;
	*) die "NODE must be hub, spoke-a or spoke-b" ;;
	esac
}

inject() { # fault name [ms]
	require_up
	case ${1:-} in
	kill-direct) kill_direct && echo "lab: direct path between the spokes cut" ;;
	relay-delay)
		case ${2:-} in '' | *[!0-9]*) die "relay-delay needs MS, a whole number of milliseconds" ;; esac
		relay_delay "$2" && echo "lab: the relay path delayed by ${2} ms each way" ;;
	restore) clear_faults && echo "lab: faults cleared" ;;
	*) die "NAME must be kill-direct, relay-delay or restore" ;;
	esac
	echo "fault ${1:-} ${2:-}" >"$OUT/current"
}

case ${1:-} in
up | down) "$1" ;;
shell) shell "${2:-}" ;;
fault) inject "${2:-}" "${3:-}" ;;
watchdog) watchdog abort ;;
*) die "usage: lab.sh up | down | shell NODE | fault kill-direct|relay-delay MS|restore" ;;
esac
